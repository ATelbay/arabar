import Foundation

struct UsageEvent: Codable, Equatable {
    let timestamp: Date
    let provider: Provider
    let model: String
    let sessionId: String
    let messageId: String?

    /// Token categories are mutually exclusive; readers normalize provider subsets.
    let inputTokens: Int
    let outputTokens: Int

    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    /// Subset of cacheCreationTokens written with a one-hour TTL.
    let cacheCreation1hTokens: Int?

    let cachedTokens: Int
    let reasoningTokens: Int

    /// Exact cost reported by the source, when available (for example Pi sessions).
    /// Falls back to the local pricing table when nil.
    let recordedCostUSD: Double?

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens + cachedTokens + reasoningTokens
    }

    init(
        timestamp: Date,
        provider: Provider,
        model: String,
        sessionId: String,
        messageId: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheCreation1hTokens: Int? = nil,
        cachedTokens: Int = 0,
        reasoningTokens: Int = 0,
        recordedCostUSD: Double? = nil
    ) {
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.sessionId = sessionId
        self.messageId = messageId
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheCreationTokens = max(0, cacheCreationTokens)
        self.cacheCreation1hTokens = cacheCreation1hTokens.map { min(max(0, $0), max(0, cacheCreationTokens)) }
        self.cachedTokens = max(0, cachedTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        self.recordedCostUSD = recordedCostUSD
    }
}
