import Foundation

final class Aggregator {
    init() {}

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
        if let recordedCostUSD = event.recordedCostUSD, recordedCostUSD.isFinite, recordedCostUSD >= 0 {
            return recordedCostUSD
        }

        let price: Pricing.ModelPrice?
        switch event.provider {
        case .claude:
            price = Pricing.claudePrice(for: event.model)
        case .codex:
            price = Pricing.openAIPrice(for: event.model)
        case .gemini, .kimi, .glm:
            // Account quota providers do not use local token/cost accounting.
            price = nil
        }

        guard let modelPrice = price else { return 0 }

        var total = 0.0

        // Input tokens
        total += Double(event.inputTokens) * modelPrice.inputPerMTok / 1_000_000

        // Output tokens
        total += Double(event.outputTokens) * modelPrice.outputPerMTok / 1_000_000

        switch event.provider {
        case .claude:
            // Cache read (hit)
            total += Double(event.cacheReadTokens) * modelPrice.cachedInputPerMTok / 1_000_000

            // Cache write: prefer 5-minute tier, fall back to 1-hour, then ignore
            let cacheWritePrice = modelPrice.cacheWrite5mPerMTok ?? modelPrice.cacheWrite1hPerMTok
            if let cwPrice = cacheWritePrice {
                let oneHourTokens = min(event.cacheCreationTokens, max(0, event.cacheCreation1hTokens ?? 0))
                total += Double(event.cacheCreationTokens - oneHourTokens) * cwPrice / 1_000_000
                total += Double(oneHourTokens) * (modelPrice.cacheWrite1hPerMTok ?? cwPrice) / 1_000_000
            }

        case .codex:
            // Cached input tokens
            total += Double(event.cachedTokens) * modelPrice.cachedInputPerMTok / 1_000_000

            // Reasoning tokens billed at output rate
            total += Double(event.reasoningTokens) * modelPrice.outputPerMTok / 1_000_000
        case .gemini, .kimi, .glm:
            break
        }

        return total
    }

    // MARK: - Private helpers

    private func deduplicated(_ events: [UsageEvent]) -> [UsageEvent] {
        // messageId == nil → keep as-is (use UUID to ensure uniqueness in key)
        var seen: [String: UsageEvent] = [:]
        for event in events {
            let key = "\(event.provider.rawValue)-\(event.messageId ?? UUID().uuidString)"
            if let previous = seen[key], previous.totalTokens > event.totalTokens {
                continue
            }
            seen[key] = event
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
        let inWindow = events.filter { $0.timestamp >= cutoff && $0.timestamp <= now }

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
            sum + event.totalTokens
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
        return (nil, .unknown)
    }
}
