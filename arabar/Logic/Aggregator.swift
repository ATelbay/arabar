import Foundation

final class Aggregator {
    let claudePlan: PlanLimits.ClaudePlan
    let chatgptPlan: PlanLimits.ChatGPTPlan

    init(
        claudePlan: PlanLimits.ClaudePlan = .pro,
        chatgptPlan: PlanLimits.ChatGPTPlan = .plus
    ) {
        self.claudePlan = claudePlan
        self.chatgptPlan = chatgptPlan
    }

    // MARK: - Main entry point

    /// Accepts a combined array of events from both readers.
    /// Performs global deduplication by (provider, messageId).
    /// Returns one snapshot per provider.
    func aggregate(events: [UsageEvent], now: Date = Date()) -> [Provider: UsageSnapshot] {
        let unique = deduplicated(events)
        var result: [Provider: UsageSnapshot] = [:]

        for provider in Provider.allCases {
            let providerEvents = unique.filter { $0.provider == provider }
            let snapshot = makeSnapshot(
                provider: provider,
                events: providerEvents,
                now: now
            )
            result[provider] = snapshot
        }

        return result
    }

    // MARK: - Cost calculation

    /// Calculates cost for a single event using Pricing tables.
    /// Returns 0 if model is not found — does not crash.
    static func cost(for event: UsageEvent) -> Double {
        let price: Pricing.ModelPrice?
        switch event.provider {
        case .claude:
            price = Pricing.claudeModels[event.model]
        case .codex:
            price = Pricing.openaiModels[event.model]
        }

        guard let p = price else { return 0 }

        var total = 0.0

        // Input tokens
        total += Double(event.inputTokens) * p.inputPerMTok / 1_000_000

        // Output tokens
        total += Double(event.outputTokens) * p.outputPerMTok / 1_000_000

        switch event.provider {
        case .claude:
            // Cache read (hit)
            total += Double(event.cacheReadTokens) * p.cachedInputPerMTok / 1_000_000

            // Cache write: prefer 5-minute tier, fall back to 1-hour, then ignore
            let cacheWritePrice = p.cacheWrite5mPerMTok ?? p.cacheWrite1hPerMTok
            if let cwPrice = cacheWritePrice {
                total += Double(event.cacheCreationTokens) * cwPrice / 1_000_000
            }

        case .codex:
            // Cached input tokens
            total += Double(event.cachedTokens) * p.cachedInputPerMTok / 1_000_000

            // Reasoning tokens billed at output rate
            total += Double(event.reasoningTokens) * p.outputPerMTok / 1_000_000
        }

        return total
    }

    // MARK: - Private helpers

    private func deduplicated(_ events: [UsageEvent]) -> [UsageEvent] {
        // messageId == nil → keep as-is (use UUID to ensure uniqueness in key)
        var seen: [String: UsageEvent] = [:]
        for event in events {
            let key = "\(event.provider.rawValue)-\(event.messageId ?? UUID().uuidString)"
            if seen[key] == nil {
                seen[key] = event
            }
        }
        return Array(seen.values)
    }

    private func makeSnapshot(
        provider: Provider,
        events: [UsageEvent],
        now: Date
    ) -> UsageSnapshot {
        let sessionWindow = makeWindowSnapshot(
            provider: provider,
            events: events,
            durationHours: 5,
            now: now
        )
        let weeklyWindow = makeWindowSnapshot(
            provider: provider,
            events: events,
            durationHours: 168,
            now: now
        )

        return UsageSnapshot(
            provider: provider,
            generatedAt: now,
            sessionWindow: sessionWindow,
            weeklyWindow: weeklyWindow,
            totalEventsInPeriod: events.count
        )
    }

    private func makeWindowSnapshot(
        provider: Provider,
        events: [UsageEvent],
        durationHours: Int,
        now: Date
    ) -> WindowSnapshot {
        let windowSeconds = TimeInterval(durationHours) * 3600
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let inWindow = events.filter { $0.timestamp >= cutoff }

        guard !inWindow.isEmpty else {
            let (emptyPct, emptySource) = percentUsedWithSource(
                tokens: 0,
                provider: provider,
                durationHours: durationHours
            )
            return WindowSnapshot(
                durationHours: durationHours,
                tokensUsed: 0,
                costUSD: 0,
                percentUsed: emptyPct,
                resetAt: nil,
                percentSource: emptySource
            )
        }

        let firstEvent = inWindow.min(by: { $0.timestamp < $1.timestamp })!
        let resetAt = firstEvent.timestamp.addingTimeInterval(windowSeconds)

        let tokensUsed = inWindow.reduce(0) { sum, event in
            sum
                + event.inputTokens
                + event.outputTokens
                + event.cacheReadTokens
                + event.cacheCreationTokens
                + event.cachedTokens
                + event.reasoningTokens
        }

        let costUSD = inWindow.reduce(0.0) { $0 + Aggregator.cost(for: $1) }

        let (pct, source) = percentUsedWithSource(
            tokens: tokensUsed,
            provider: provider,
            durationHours: durationHours
        )

        return WindowSnapshot(
            durationHours: durationHours,
            tokensUsed: tokensUsed,
            costUSD: costUSD,
            percentUsed: pct,
            resetAt: resetAt,
            percentSource: source
        )
    }

    private func percentUsedWithSource(
        tokens: Int,
        provider: Provider,
        durationHours: Int
    ) -> (Double?, PercentSource) {
        let windows: [PlanLimits.Window]
        switch provider {
        case .claude:
            windows = PlanLimits.claudeLimits(for: claudePlan)
        case .codex:
            windows = PlanLimits.chatgptLimits(for: chatgptPlan)
        }

        guard let window = windows.first(where: { $0.durationHours == durationHours }) else {
            return (nil, .unknown)
        }

        guard let maxTokens = window.maxTokens else {
            return (nil, .unknown)
        }

        let raw = Double(tokens) / Double(maxTokens)
        return (max(0.0, min(1.0, raw)), .estimated)
    }
}
