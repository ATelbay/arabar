import Foundation
import SwiftUI
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    // MARK: - Primary snapshots (shown in menubar & main section)
    @Published var claudeSnapshot: UsageSnapshot?       // subscription source (cookies + JSONL)
    @Published var codexSnapshot: UsageSnapshot?        // subscription source (cookies + JSONL)
    @Published var accountQuotas: [Provider: AccountQuotaSnapshot] = [:]
    @Published var accountQuotaErrors: [Provider: String] = [:]
    private let accountQuotaReader = AccountQuotaReader()
    private var quotaConfigurations: [Provider: AccountQuotaConfiguration] = [:]

    func snapshot(for provider: Provider) -> UsageSnapshot? {
        switch provider {
        case .claude: return usesAPIDisplay(for: provider) ? claudeApiSnapshot : claudeSnapshot
        case .codex: return usesAPIDisplay(for: provider) ? codexApiSnapshot : codexSnapshot
        case .gemini, .kimi, .glm: return nil
        }
    }

    func usesAPIDisplay(for provider: Provider) -> Bool {
        let key = provider == .claude ? "display.source.claude" : "display.source.openai"
        return !provider.usesAccountQuota && UserDefaults.standard.string(forKey: key) == "api"
    }

    func status(for provider: Provider) -> StatusInfo? {
        switch provider {
        case .claude: return claudeStatus
        case .codex: return codexStatus
        case .gemini, .kimi, .glm: return nil
        }
    }

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

    // MARK: - Session-expired state (cookies present but the login token is dead → re-login)
    @Published var claudeSessionExpired: Bool = false
    @Published var codexSessionExpired: Bool = false

    // MARK: - Menubar rotation
    // Driven from here so the Timer lives in a stable @StateObject instead of a View struct
    // (View structs are re-created on every parent re-render, which resets local Timer publishers).
    @Published var rotationIndex: Int = 0
    private var rotationTimer: Timer?

    private let claudeReader = ClaudeUsageReader()
    private let codexReader = CodexUsageReader()
    private let claudePiReader = PiUsageReader(targetProvider: .claude)
    private let codexPiReader = PiUsageReader(targetProvider: .codex)
    private let aggregator = Aggregator()

    // Hoisted cookie readers — avoid re-allocating on every refresh
    private let claudeCookieReader = ClaudeCookiesReader()
    private let openaiCookieReader = OpenAICookiesReader()

    private var eventBuffer: [UsageEvent] = []
    private var bufferLoadTask: Task<[UsageEvent], Never>?
    private let bufferWriteQueue = DispatchQueue(label: "arabar.event-buffer")
    // Per-provider rebuild tracking to avoid race when both providers run in parallel
    private var initialRebuildDone: Set<Provider> = []
    private var pendingRebuilds: Set<Provider> = []
    private var localReadFailures: Set<Provider> = []
    private let bufferRetentionHours: Double = 192  // 168h week + 24h safety

    // Sticky-snapshot invalidation: track last-known cookies-enabled state
    private var lastClaudeCookiesEnabled: Bool
    private var lastOpenAICookiesEnabled: Bool
    private var lastClaudeCookieSource: String
    private var lastOpenAICookieSource: String
    private var apiKeyRevisions: [String: Int] = [:]
    private var settingsRevision: Int = 0
    private var cancellables: Set<AnyCancellable> = []

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
        return dir.appendingPathComponent("event_buffer_v2.json")
    }()

    init() {
        lastClaudeCookiesEnabled = UserDefaults.standard.bool(forKey: "cookies.enabled.claude")
        lastOpenAICookiesEnabled = UserDefaults.standard.bool(forKey: "cookies.enabled.openai")
        lastClaudeCookieSource = UserDefaults.standard.string(forKey: "cookies.source.claude") ?? "safari"
        lastOpenAICookieSource = UserDefaults.standard.string(forKey: "cookies.source.openai") ?? "safari"
        for account in [KeychainAccount.anthropicAdminKey, KeychainAccount.openaiAdminKey] {
            apiKeyRevisions[account] = UserDefaults.standard.integer(forKey: "\(account).revision")
        }
        let url = bufferFile
        bufferLoadTask = Task.detached(priority: .userInitiated) {
            Self.loadBufferFromDisk(url: url)
        }

        // Rotation timer (30s) — drives menubar provider cycling
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rotationIndex = (self?.rotationIndex ?? 0) &+ 1
            }
        }

        // Invalidate sticky snapshots when the user toggles cookies in Settings
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                for account in [KeychainAccount.anthropicAdminKey, KeychainAccount.openaiAdminKey] {
                    let revision = UserDefaults.standard.integer(forKey: "\(account).revision")
                    if self.apiKeyRevisions[account] != revision {
                        self.apiKeyRevisions[account] = revision
                        self.settingsRevision &+= 1
                        if account == KeychainAccount.anthropicAdminKey { self.claudeApiSnapshot = nil }
                        else { self.codexApiSnapshot = nil }
                    }
                }
                for provider in Provider.accountQuotaProviders {
                    let configuration = AccountQuotaConfiguration.load(provider: provider)
                    if self.quotaConfigurations[provider] != configuration {
                        self.accountQuotas[provider] = nil
                        self.accountQuotaErrors[provider] = nil
                        self.quotaConfigurations[provider] = configuration
                    }
                }
                let cookiesClaudeOn = UserDefaults.standard.bool(forKey: "cookies.enabled.claude")
                let cookiesOpenAIOn = UserDefaults.standard.bool(forKey: "cookies.enabled.openai")
                let claudeSource = UserDefaults.standard.string(forKey: "cookies.source.claude") ?? "safari"
                let openAISource = UserDefaults.standard.string(forKey: "cookies.source.openai") ?? "safari"
                if self.lastClaudeCookiesEnabled != cookiesClaudeOn || self.lastClaudeCookieSource != claudeSource {
                    self.settingsRevision &+= 1
                    self.claudeSnapshot = nil
                    self.claudeSessionExpired = false
                    self.claudeCookieExpiresAt = nil
                    self.lastClaudeCookiesEnabled = cookiesClaudeOn
                    self.lastClaudeCookieSource = claudeSource
                }
                if self.lastOpenAICookiesEnabled != cookiesOpenAIOn || self.lastOpenAICookieSource != openAISource {
                    self.settingsRevision &+= 1
                    self.codexSnapshot = nil
                    self.codexSessionExpired = false
                    self.codexCookieExpiresAt = nil
                    self.lastOpenAICookiesEnabled = cookiesOpenAIOn
                    self.lastOpenAICookieSource = openAISource
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        localReadFailures.removeAll()
        defer { isRefreshing = false }

        let now = Date()
        let revisionAtStart = settingsRevision

        // Run all sources in parallel
        async let claudeSubTask  = computeSubscriptionSnapshot(provider: .claude, now: now)
        async let codexSubTask   = computeSubscriptionSnapshot(provider: .codex,  now: now)
        async let claudeApiTask  = computeAPISnapshot(provider: .claude, now: now)
        async let codexApiTask   = computeAPISnapshot(provider: .codex,  now: now)
        async let claudeStatTask = StatusPagePoller.fetch(provider: .claude)
        async let codexStatTask  = StatusPagePoller.fetch(provider: .codex)
        async let accountQuotaTask = refreshAccountQuotas()

        let claudeSubResult = await claudeSubTask
        let codexSubResult = await codexSubTask
        let claudeApiResult = await claudeApiTask
        let codexApiResult = await codexApiTask
        let quotaResult = await accountQuotaTask
        let usageResults = [claudeSubResult, codexSubResult, claudeApiResult, codexApiResult, quotaResult]

        if settingsRevision != revisionAtStart {
            // Cookie settings changed while this refresh was in flight. Do not let
            // results fetched with the old browser/source repopulate sticky snapshots.
            self.claudeStatus = await claudeStatTask
            self.codexStatus = await codexStatTask
            return
        }

        self.claudeSnapshot    = preferUseful(new: claudeSubResult.snapshot,  current: claudeSnapshot,    now: now)
        self.codexSnapshot     = preferUseful(new: codexSubResult.snapshot,   current: codexSnapshot,     now: now)
        self.claudeSessionExpired = claudeSubResult.sessionExpired
        self.codexSessionExpired  = codexSubResult.sessionExpired
        self.claudeApiSnapshot = preferUseful(new: claudeApiResult.snapshot,  current: claudeApiSnapshot, now: now)
        self.codexApiSnapshot  = preferUseful(new: codexApiResult.snapshot,   current: codexApiSnapshot,  now: now)
        self.claudeStatus      = await claudeStatTask
        self.codexStatus       = await codexStatTask

        // The footer timestamp means "last successful usage refresh".
        // Do not move it forward when a configured usage request failed and we only kept
        // sticky/cached data, otherwise offline/stale data looks freshly updated.
        if usageResults.contains(where: { $0.didRefreshSource })
            && !usageResults.contains(where: { $0.didFailSource }) {
            self.lastRefreshAt = now
        }

        // Reading browser databases can block; only inspect them after explicit opt-in.
        async let claudeExpiry = Task.detached { CookieExpiry.forProvider(.claude) }.value
        async let codexExpiry = Task.detached { CookieExpiry.forProvider(.codex) }.value
        let expiryDates = await (claudeExpiry, codexExpiry)
        if settingsRevision == revisionAtStart {
            self.claudeCookieExpiresAt = expiryDates.0
            self.codexCookieExpiresAt = expiryDates.1
        }
    }

    // MARK: - Sticky-snapshot helpers

    private struct SnapshotRefreshResult {
        let snapshot: UsageSnapshot?
        let didRefreshSource: Bool
        let didFailSource: Bool
        var sessionExpired: Bool = false
    }

    /// True when an error means the browser login token is dead (cookies present but rejected),
    /// so the fix is a re-login rather than a transient retry.
    private static func isSessionExpiredError(_ error: Error) -> Bool {
        if case OpenAICookiesError.sessionExchangeFailed = error { return true }
        if case OpenAICookiesError.httpError(let statusCode) = error,
           statusCode == 401 || statusCode == 403 { return true }
        if case ClaudeCookiesError.httpError(let statusCode) = error,
           statusCode == 401 || statusCode == 403 { return true }
        return false
    }

    /// Returns the most useful snapshot between a freshly-fetched value and the previously cached one.
    /// If the new snapshot has non-expired authoritative percent data, it wins.
    /// If the new snapshot is transient/degraded but the current one still has fresh/stale
    /// authoritative data, keep the current one briefly to avoid flicker.
    /// Expired authoritative sticky snapshots must not mask a newer JSONL/unknown fallback.
    private func preferUseful(new: UsageSnapshot?, current: UsageSnapshot?, now: Date) -> UsageSnapshot? {
        SubscriptionSnapshotPolicy.preferUseful(new: new, current: current, now: now)
    }

    // MARK: - Subscription source: cookies → JSONL fallback

    private func computeSubscriptionSnapshot(provider: Provider, now: Date) async -> SnapshotRefreshResult {
        guard !provider.usesAccountQuota else {
            return SnapshotRefreshResult(snapshot: nil, didRefreshSource: false, didFailSource: false)
        }
        let cookiesKey = provider == .claude ? "cookies.enabled.claude" : "cookies.enabled.openai"
        if UserDefaults.standard.bool(forKey: cookiesKey) {
            // Kick off JSONL in parallel — it's cheap (in-memory buffer after first load)
            async let jsonlTask = jsonlSnapshot(for: provider, now: now)
            do {
                let cookiesSnap: UsageSnapshot
                switch provider {
                case .claude:
                    cookiesSnap = try await claudeCookieReader.fetchSnapshot()
                case .codex:
                    cookiesSnap = try await openaiCookieReader.fetchSnapshot()
                case .gemini, .kimi, .glm:
                    return SnapshotRefreshResult(snapshot: await jsonlTask, didRefreshSource: false, didFailSource: false)
                }
                let jsonlSnap = await jsonlTask
                return SnapshotRefreshResult(
                    snapshot: mergedSnapshot(cookies: cookiesSnap, jsonl: jsonlSnap),
                    didRefreshSource: true,
                    didFailSource: localReadFailures.contains(provider)
                )
            } catch {
                // Non-fatal: fall through to JSONL result already computing, but do not
                // mark the refresh timestamp as successful: the configured remote usage
                // request failed, so any sticky authoritative snapshot remains stale.
                self.lastError = "\(provider) cookies: \(error.localizedDescription)"
                return SnapshotRefreshResult(
                    snapshot: await jsonlTask,
                    didRefreshSource: false,
                    didFailSource: true,
                    sessionExpired: Self.isSessionExpiredError(error)
                )
            }
        }

        // JSONL only (cookies disabled)
        let jsonlSnap = await jsonlSnapshot(for: provider, now: now)
        return SnapshotRefreshResult(
            snapshot: jsonlSnap,
            didRefreshSource: jsonlSnap != nil,
            didFailSource: localReadFailures.contains(provider)
        )
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
    /// When JSONL has zero tokens (no local log yet), fall back to cookies.tokensUsed for semantic correctness.
    private func mergedWindow(cookies: WindowSnapshot, jsonl: WindowSnapshot) -> WindowSnapshot {
        let tokens = jsonl.tokensUsed > 0 ? jsonl.tokensUsed : cookies.tokensUsed
        let cost   = jsonl.tokensUsed > 0 ? jsonl.costUSD    : cookies.costUSD
        return WindowSnapshot(
            durationHours: cookies.durationHours,
            tokensUsed: tokens,
            costUSD: cost,
            percentUsed: cookies.percentUsed,
            resetAt: cookies.resetAt,
            percentSource: cookies.percentSource
        )
    }

    // MARK: - API source: Admin key only

    private func computeAPISnapshot(provider: Provider, now: Date) async -> SnapshotRefreshResult {
        do {
            let events: [UsageEvent]
            switch provider {
            case .claude:
                events = try await AnthropicAdminAPIReader().fetchEvents(lookbackDays: 7)
            case .codex:
                events = try await OpenAIUsageAPIReader().fetchEvents(lookbackDays: 7)
            case .gemini, .kimi, .glm:
                return SnapshotRefreshResult(snapshot: nil, didRefreshSource: false, didFailSource: false)
            }
            let snapshots = aggregator.aggregate(events: events, now: now)
            return SnapshotRefreshResult(
                snapshot: snapshots[provider],
                didRefreshSource: true,
                didFailSource: false
            )
        } catch AnthropicAdminAPIError.missingKey {
            // No key configured = source is not active, not a failed refresh.
            return SnapshotRefreshResult(snapshot: nil, didRefreshSource: false, didFailSource: false)
        } catch AnthropicAdminAPIError.disabled {
            return SnapshotRefreshResult(snapshot: nil, didRefreshSource: false, didFailSource: false)
        } catch OpenAIUsageAPIError.missingKey {
            return SnapshotRefreshResult(snapshot: nil, didRefreshSource: false, didFailSource: false)
        } catch OpenAIUsageAPIError.disabled {
            return SnapshotRefreshResult(snapshot: nil, didRefreshSource: false, didFailSource: false)
        } catch {
            lastError = "\(provider) API: \(error.localizedDescription)"
            return SnapshotRefreshResult(snapshot: nil, didRefreshSource: false, didFailSource: true)
        }
    }

    // MARK: - JSONL per-provider snapshot

    private func refreshAccountQuotas() async -> SnapshotRefreshResult {
        var didRefresh = false
        var didFail = false
        for provider in Provider.accountQuotaProviders {
            let configuration = AccountQuotaConfiguration.load(provider: provider)
            if quotaConfigurations[provider] != configuration {
                accountQuotas[provider] = nil
                accountQuotaErrors[provider] = nil
                quotaConfigurations[provider] = configuration
            }
            guard configuration.enabled else { continue }
            do {
                let snapshot = try await accountQuotaReader.fetch(configuration: configuration)
                guard AccountQuotaConfiguration.load(provider: provider) == configuration else { continue }
                accountQuotas[provider] = snapshot
                accountQuotaErrors[provider] = nil
                didRefresh = true
            } catch {
                guard AccountQuotaConfiguration.load(provider: provider) == configuration else { continue }
                accountQuotaErrors[provider] = error.localizedDescription
                if (error as? AccountQuotaError)?.invalidatesSnapshot == true {
                    accountQuotas[provider] = nil
                }
                didFail = true
            }
        }
        return SnapshotRefreshResult(snapshot: nil, didRefreshSource: didRefresh, didFailSource: didFail)
    }

    private func jsonlSnapshot(for provider: Provider, now: Date) async -> UsageSnapshot? {
        if let loadTask = bufferLoadTask {
            let loaded = await loadTask.value
            // Both providers may await the same load. Apply it once before appending deltas.
            if bufferLoadTask != nil {
                eventBuffer = loaded
                bufferLoadTask = nil
            }
        }
        let hasBufferedEvents = eventBuffer.contains { $0.provider == provider }
        let needsRebuild = pendingRebuilds.contains(provider) || (!hasBufferedEvents && !initialRebuildDone.contains(provider))
        if needsRebuild { pendingRebuilds.insert(provider) }
        initialRebuildDone.insert(provider)

        let read: ([UsageEvent], [String])
        switch provider {
        case .claude:
            let reader = claudeReader
            let piReader = claudePiReader
            read = await Task.detached(priority: .userInitiated) {
                Self.readLocalSources([
                    { needsRebuild ? try reader.rebuildAll() : try reader.fetchNewEvents() },
                    { needsRebuild ? try piReader.rebuildAll() : try piReader.fetchNewEvents() }
                ])
            }.value
        case .codex:
            let reader = codexReader
            let piReader = codexPiReader
            read = await Task.detached(priority: .userInitiated) {
                Self.readLocalSources([
                    { needsRebuild ? try reader.rebuildAll() : try reader.fetchNewEvents() },
                    { needsRebuild ? try piReader.rebuildAll() : try piReader.fetchNewEvents() }
                ])
            }.value
        case .gemini, .kimi, .glm:
            return nil
        }
        let newEvents = read.0
        if read.1.isEmpty {
            pendingRebuilds.remove(provider)
        } else {
            localReadFailures.insert(provider)
            lastError = "\(provider) JSONL: " + read.1.joined(separator: "; ")
        }

        eventBuffer.append(contentsOf: newEvents)
        pruneOldEvents(now: now)
        saveBuffer()

        let filtered = eventBuffer.filter { $0.provider == provider }
        let snapshots = aggregator.aggregate(events: filtered, now: now)
        return snapshots[provider]
    }

    nonisolated static func readLocalSources(_ sources: [() throws -> [UsageEvent]]) -> ([UsageEvent], [String]) {
        var events: [UsageEvent] = []
        var errors: [String] = []
        for read in sources {
            do { events.append(contentsOf: try read()) }
            catch { errors.append(error.localizedDescription) }
        }
        return (events, errors)
    }

    // MARK: - Buffer management

    private func pruneOldEvents(now: Date) {
        let cutoff = now.addingTimeInterval(-bufferRetentionHours * 3600)
        eventBuffer.removeAll { $0.timestamp < cutoff }
    }

    private nonisolated static func loadBufferFromDisk(url: URL) -> [UsageEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = (try? decoder.decode([UsageEvent].self, from: data)) ?? []
        let cutoff = Date().addingTimeInterval(-192 * 3600)
        return events.filter { $0.timestamp >= cutoff }
    }

    private func saveBuffer() {
        let snapshot = eventBuffer
        let url = bufferFile
        bufferWriteQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                // silently fail — next refresh retries
            }
        }
    }
}
