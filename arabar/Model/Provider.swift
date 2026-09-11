import Foundation

enum Provider: String, Codable, CaseIterable {
    case claude
    case codex
    case gemini
    case kimi
    case glm

    static let accountQuotaProviders: [Provider] = [.gemini, .kimi, .glm]

    var usesAccountQuota: Bool { Self.accountQuotaProviders.contains(self) }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "ChatGPT / Codex"
        case .gemini: return "Gemini"
        case .kimi: return "Kimi"
        case .glm: return "GLM"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: return "brain"
        case .codex: return "message.fill"
        case .gemini: return "sparkles"
        case .kimi: return "moon.fill"
        case .glm: return "square.stack.3d.up.fill"
        }
    }
}
