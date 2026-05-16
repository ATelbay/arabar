import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    // MARK: - Primary snapshots (shown in menubar & main section)
    @Published var claudeSnapshot: UsageSnapshot?       // subscription source (cookies or JSONL); overridden to api if display.source.claude == "api"
    @Published var codexSnapshot: UsageSnapshot?        // same for codex

    // MARK: - API-tier snapshots (separate section if user configured both)
    @Published var claudeApiSnapshot: UsageSnapshot?    // Admin API key
    @Published var codexApiSnapshot: UsageSnapshot?     // OpenAI Admin API key

    // MARK: - Status / meta
    @Published var claudeStatus: StatusInfo?
    @Published var codexStatus: StatusInfo?
    @Published var lastRefreshAt: Date?
    @Published var isRefreshing: Bool = false
    @Published var lastError: String?

    // MARK: - Cookie expiry (for TTL warning in dropdown)
    @Published var claudeCookieExpiresAt: Date?
    @Published var codexCookieExpiresAt: Date?

    private let claudeReader = ClaudeUsageReader()
    private let codexReader = CodexUsageReader()
    private let aggregator = Aggregator()

    private var eventBuffer: [UsageEvent] = []
    private var didInitialRebuild: Bool = false
    private let bufferRetentionHours: Double = 192  // 168h week + 24h safety

    private let bufferFile: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let dir = support.appendingPathComponent("arabar", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("event_buffer.json")
    }()

    init() {
        loadBuffer()
    }

    // MARK: - Public refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        let now = Date()
        let claudeDisplaySource = UserDefaults.standard.string(forKey: "display.source.claude") ?? "subscription"
        let codexDisplaySource  = UserDefaults.standard.string(forKey: "display.source.openai") ?? "subscription"

        // Run all sources in parallel
        async let claudeSubTask  = computeSubscriptionSnapshot(provider: .claude, now: now)
        async let codexSubTask   = computeSubscriptionSnapshot(provider: .codex,  now: now)
        async let claudeApiTask  = computeAPISnapshot(provider: .claude, now: now)
        async let codexApiTask   = computeAPISnapshot(provider: .codex,  now: now)
        async let claudeStatTask = StatusPagePoller.fetch(provider: .claude)
        async let codexStatTask  = StatusPagePoller.fetch(provider: .codex)

        self.claudeSnapshot    = preferUseful(new: await claudeSubTask,  current: claudeSnapshot)
        self.codexSnapshot     = preferUseful(new: await codexSubTask,   current: codexSnapshot)
        self.claudeApiSnapshot = preferUseful(new: await claudeApiTask,  current: claudeApiSnapshot)
        self.codexApiSnapshot  = preferUseful(new: await codexApiTask,   current: codexApiSnapshot)
        self.claudeStatus      = await claudeStatTask
        self.codexStatus       = await codexStatTask
        self.lastRefreshAt     = now

        // Update cookie expiry dates for TTL warning UX
        self.claudeCookieExpiresAt = await Task.detached { CookieExpiry.forProvider(.claude) }.value
        self.codexCookieExpiresAt  = await Task.detached { CookieExpiry.forProvider(.codex) }.value

        // Override primary snapshot to API tier if user selected "api" as display source
        if claudeDisplaySource == "api", let apiSnap = claudeApiSnapshot {
            self.claudeSnapshot = apiSnap
        }
        if codexDisplaySource == "api", let apiSnap = codexApiSnapshot {
            self.codexSnapshot = apiSnap
        }
    }

    // MARK: - Sticky-snapshot helpers

    /// Returns the most useful snapshot between a freshly-fetched value and the previously cached one.
    /// If the new snapshot is useful (has authoritative percentSource), it wins.
    /// If the new snapshot is transient/degraded but the current one is useful, keep the current one.
    /// This prevents a single bad refresh cycle from flickering the display to ukwn/estimated.
    ///
    /// TODO: If the user disables cookies in Settings, the sticky cookies snapshot will persist until
    /// process restart. Invalidation on settings change is out of scope.
    private func preferUseful(new: UsageSnapshot?, current: UsageSnapshot?) -> UsageSnapshot? {
        guard let current = current else { return new }
        if isUseful(new) { return new }
        if isUseful(current) { return current }
        return new
    }

    private func isUseful(_ snap: UsageSnapshot?) -> Bool {
        guard let s = snap else { return false }
        return s.sessionWindow.percentSource == .authoritative
            || s.weeklyWindow.percentSource == .authoritative
    }

    // MARK: - Subscription source: cookies → JSONL fallback

    private func computeSubscriptionSnapshot(provider: Provider, now: Date) async -> UsageSnapshot? {
        let cookiesKey = provider == .claude ? "cookies.enabled.claude" : "cookies.enabled.openai"
        if UserDefaults.standard.bool(forKey: cookiesKey) {
            // Kick off JSONL in parallel — it's cheap (in-memory buffer after first load)
            async let jsonlTask = jsonlSnapshot(for: provider, now: now)
            do {
                let cookiesSnap: UsageSnapshot
                switch provider {
                case .claude:
                    cookiesSnap = try await ClaudeCookiesReader().fetchSnapshot()
                case .codex:
                    cookiesSnap = try await OpenAICookiesReader().fetchSnapshot()
                }
                let jsonlSnap = await jsonlTask
                return mergedSnapshot(cookies: cookiesSnap, jsonl: jsonlSnap)
            } catch {
                // Non-fatal: fall through to JSONL result already computing
                self.lastError = "\(provider) cookies: \(error.localizedDescription)"
                return await jsonlTask
            }
        }

        // JSONL only (cookies disabled)
        return await jsonlSnapshot(for: provider, now: now)
    }

    // MARK: - Merge helpers

    /// Merges cookies (authoritative %) and JSONL (real token counts) snapshots.
    private func mergedSnapshot(cookies: UsageSnapshot, jsonl: UsageSnapshot?) -> UsageSnapshot {
        guard let jsonl else { return cookies }
        return UsageSnapshot(
            provider: cookies.provider,
            generatedAt: cookies.generatedAt,
            sessionWindow: mergedWindow(cookies: cookies.sessionWindow, jsonl: jsonl.sessionWindow),
            weeklyWindow: mergedWindow(cookies: cookies.weeklyWindow, jsonl: jsonl.weeklyWindow),
            totalEventsInPeriod: jsonl.totalEventsInPeriod
        )
    }

    /// Cookies supplies authoritative % and resetAt; JSONL supplies real token counts and cost.
    private func mergedWindow(cookies: WindowSnapshot, jsonl: WindowSnapshot) -> WindowSnapshot {
        return WindowSnapshot(
            durationHours: cookies.durationHours,
            tokensUsed: jsonl.tokensUsed,
            costUSD: jsonl.costUSD,
            percentUsed: cookies.percentUsed,
            resetAt: cookies.resetAt,
            percentSource: cookies.percentSource
        )
    }

    // MARK: - API source: Admin key only

    private func computeAPISnapshot(provider: Provider, now: Date) async -> UsageSnapshot? {
        do {
            let events: [UsageEvent]
            switch provider {
            case .claude:
                events = try await AnthropicAdminAPIReader().fetchEvents(lookbackDays: 30)
            case .codex:
                events = try await OpenAIUsageAPIReader().fetchEvents(lookbackDays: 30)
            }
            let snapshots = aggregator.aggregate(events: events, now: now)
            return snapshots[provider]
        } catch {
            // .missingKey is expected when no key is configured — silently return nil
            return nil
        }
    }

    // MARK: - JSONL per-provider snapshot

    private func jsonlSnapshot(for provider: Provider, now: Date) async -> UsageSnapshot? {
        let needsRebuild = eventBuffer.isEmpty && !didInitialRebuild
        didInitialRebuild = true

        let newEvents: [UsageEvent]
        do {
            switch provider {
            case .claude:
                newEvents = needsRebuild
                    ? try claudeReader.rebuildAll()
                    : try claudeReader.fetchNewEvents()
            case .codex:
                newEvents = needsRebuild
                    ? try codexReader.rebuildAll()
                    : try codexReader.fetchNewEvents()
            }
        } catch {
            self.lastError = "\(provider) JSONL: \(error.localizedDescription)"
            return nil
        }

        eventBuffer.append(contentsOf: newEvents)
        pruneOldEvents(now: now)
        saveBuffer()

        let filtered = eventBuffer.filter { $0.provider == provider }
        let snapshots = aggregator.aggregate(events: filtered, now: now)
        return snapshots[provider]
    }

    // MARK: - Buffer management

    private func pruneOldEvents(now: Date) {
        let cutoff = now.addingTimeInterval(-bufferRetentionHours * 3600)
        eventBuffer.removeAll { $0.timestamp < cutoff }
    }

    private func loadBuffer() {
        guard let data = try? Data(contentsOf: bufferFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        eventBuffer = (try? decoder.decode([UsageEvent].self, from: data)) ?? []
        pruneOldEvents(now: Date())
    }

    private func saveBuffer() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(eventBuffer) else { return }
        try? data.write(to: bufferFile, options: .atomic)
    }
}
