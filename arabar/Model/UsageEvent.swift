import Foundation

struct UsageEvent: Codable, Equatable {
    let timestamp: Date
    let provider: Provider
    let model: String
    let sessionId: String
    let messageId: String?

    let inputTokens: Int
    let outputTokens: Int

    let cacheReadTokens: Int
    let cacheCreationTokens: Int

    let cachedTokens: Int
    let reasoningTokens: Int

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
        cachedTokens: Int = 0,
        reasoningTokens: Int = 0
    ) {
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.sessionId = sessionId
        self.messageId = messageId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
    }
}
