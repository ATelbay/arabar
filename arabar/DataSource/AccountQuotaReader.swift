import Foundation
import CoreFoundation

enum AccountQuotaError: LocalizedError {
    case disabled, missingKey, missingGeminiLogin, missingGeminiClient, unauthorized, missingProject, noQuota, invalidResponse
    case http(Int)

    var invalidatesSnapshot: Bool {
        switch self {
        case .disabled, .missingKey, .missingGeminiLogin, .missingGeminiClient, .unauthorized, .noQuota: return true
        case .missingProject, .invalidResponse, .http: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .disabled: return "Connect your account in Settings → Account limits."
        case .missingKey: return "Add your coding-plan API key in Settings → Account limits."
        case .missingGeminiLogin: return "Sign in with Google in Gemini CLI first. A readable ~/.gemini/oauth_creds.json is required."
        case .missingGeminiClient: return "Could not locate Gemini CLI’s Google login configuration. Install Gemini CLI through npm or Homebrew, then reconnect."
        case .unauthorized: return "Access rejected or expired. Reconnect your account in Settings → Account limits."
        case .missingProject: return "Google did not return a project. Enter your Code Assist project ID in Settings."
        case .noQuota: return "The account returned no supported quota data. Check your plan and account dashboard."
        case .invalidResponse: return "The provider returned an unrecognized quota response."
        case .http(let code): return "Could not refresh account limits (HTTP \(code))."
        }
    }
}

/// Reads account quotas only. No prompts, token logs, or inference requests are involved.
actor AccountQuotaReader {
    private let session: URLSession
    private var geminiToken: (credentials: Data, token: String, expiresAt: Date)?

    init(session: URLSession = .shared) { self.session = session }

    func fetch(configuration: AccountQuotaConfiguration) async throws -> AccountQuotaSnapshot {
        guard configuration.enabled else { throw AccountQuotaError.disabled }
        switch configuration.provider {
        case .gemini:
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/oauth_creds.json")
            guard let data = try? Data(contentsOf: url) else { throw AccountQuotaError.missingGeminiLogin }
            return try await fetchGemini(credentials: data, project: configuration.project)
        case .kimi, .glm:
            guard let key = KeychainStore.get(account: configuration.keychainAccount), !key.isEmpty else {
                throw AccountQuotaError.missingKey
            }
            return try await fetchKeyQuota(provider: configuration.provider, key: key, region: configuration.region)
        case .claude, .codex:
            throw AccountQuotaError.noQuota
        }
    }

    func fetchKeyQuota(provider: Provider, key: String, region: String) async throws -> AccountQuotaSnapshot {
        let url: String
        let authorization: String
        switch provider {
        case .kimi:
            url = region == "china" ? "https://api.kimi.com/coding/v1/usages" : "https://api.kimi.ai/coding/v1/usages"
            authorization = "Bearer \(key)"
        case .glm:
            let host = region == "china" ? "open.bigmodel.cn" : "api.z.ai"
            url = "https://\(host)/api/monitor/usage/quota/limit"
            // Z.ai's official quota plugin uses the raw key, without a Bearer prefix.
            authorization = key
        default: throw AccountQuotaError.noQuota
        }
        let data = try await request(url: url, authorization: authorization)
        return try Self.parse(data: data, provider: provider, now: Date())
    }

    func fetchGemini(credentials: Data, project: String) async throws -> AccountQuotaSnapshot {
        let token = try await googleAccessToken(credentials: credentials)
        do {
            return try await googleQuota(token: token, project: project)
        } catch AccountQuotaError.unauthorized {
            geminiToken = nil
            let refreshed = try await googleAccessToken(credentials: credentials, forceRefresh: true)
            return try await googleQuota(token: refreshed, project: project)
        }
    }

    private func googleQuota(token: String, project: String) async throws -> AccountQuotaSnapshot {
        let base = "https://cloudcode-pa.googleapis.com/v1internal:"
        var projectID = project.trimmingCharacters(in: .whitespacesAndNewlines)
        if projectID.isEmpty {
            let data = try await request(url: base + "loadCodeAssist", authorization: "Bearer \(token)", body: [
                "metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"],
                "mode": "HEALTH_CHECK"
            ])
            let object = try Self.object(data)
            projectID = object["cloudaicompanionProject"] as? String ?? ""
        }
        guard !projectID.isEmpty else { throw AccountQuotaError.missingProject }
        let data = try await request(url: base + "retrieveUserQuota", authorization: "Bearer \(token)",
                                     body: ["project": projectID, "userAgent": "arabar"])
        return try Self.parse(data: data, provider: .gemini, now: Date())
    }

    private func googleAccessToken(credentials: Data, forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cached = geminiToken, cached.credentials == credentials,
           cached.expiresAt.timeIntervalSinceNow > 60 { return cached.token }
        let object = try Self.object(credentials)
        if !forceRefresh, let token = object["access_token"] as? String, !token.isEmpty,
           let expiry = Self.number(object["expiry_date"]), expiry / 1000 > Date().timeIntervalSince1970 + 60 {
            return token
        }
        guard let refreshToken = object["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw AccountQuotaError.missingGeminiLogin
        }
        // Use the installed CLI's OAuth configuration; refreshed access tokens stay in memory.
        let client = try GeminiOAuthClient.load(credentials: object)
        let data = try await request(url: "https://oauth2.googleapis.com/token", authorization: nil, body: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": client.id,
            "client_secret": client.secret
        ], formEncoded: true)
        let response = try Self.object(data)
        guard let token = response["access_token"] as? String, !token.isEmpty,
              let lifetime = Self.number(response["expires_in"]), lifetime > 0 else {
            throw AccountQuotaError.unauthorized
        }
        geminiToken = (credentials, token, Date().addingTimeInterval(lifetime))
        return token
    }

    private func request(url: String, authorization: String?, body: [String: Any]? = nil, formEncoded: Bool = false) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("arabar", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            if formEncoded {
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                let encoded = body.sorted { $0.key < $1.key }.map { key, value in
                    let value = String(describing: value).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                    return "\(key)=\(value)"
                }.joined(separator: "&")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(encoded.utf8)
            } else {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AccountQuotaError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw AccountQuotaError.unauthorized
        }
        if formEncoded, response.statusCode == 400,
           let error = try? Self.object(data)["error"] as? String, error == "invalid_grant" {
            throw AccountQuotaError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else { throw AccountQuotaError.http(response.statusCode) }
        return data
    }

    // Schemas: Google Gemini CLI code_assist/types.ts; MoonshotAI/kimi-code managed-usage.ts;
    // zai-org/zai-coding-plugins glm-plan-usage/scripts/query-usage.mjs.
    static func parse(data: Data, provider: Provider, now: Date) throws -> AccountQuotaSnapshot {
        let root = try object(data)
        var windows: [AccountQuotaWindow] = []
        switch provider {
        case .gemini:
            for (index, bucket) in (root["buckets"] as? [[String: Any]] ?? []).enumerated() {
                guard let remaining = fraction(bucket["remainingFraction"]) else { continue }
                let model = bucket["modelId"] as? String ?? "Account quota"
                windows.append(.init(id: "bucket-\(index)", label: model, remainingFraction: remaining,
                                     resetAt: date(bucket["resetTime"])))
            }
        case .kimi:
            if let usage = root["usage"] as? [String: Any], let remaining = remaining(usage) {
                windows.append(.init(id: "weekly", label: usage["name"] as? String ?? "Weekly",
                                     remainingFraction: remaining, resetAt: date(usage["resetTime"])))
            }
            for (index, limit) in (root["limits"] as? [[String: Any]] ?? []).enumerated() {
                guard let detail = limit["detail"] as? [String: Any], let remaining = remaining(detail) else { continue }
                let label = limit["name"] as? String ?? kimiWindowLabel(limit["window"]) ?? "Account limit"
                windows.append(.init(id: "limit-\(index)", label: label, remainingFraction: remaining,
                                     resetAt: date(detail["resetTime"])))
            }
        case .glm:
            if let code = number(root["code"]), code == 401 || code == 403 { throw AccountQuotaError.unauthorized }
            if root["success"] as? Bool == false { throw AccountQuotaError.invalidResponse }
            if let code = number(root["code"]), code != 200 && code != 0 { throw AccountQuotaError.invalidResponse }
            let payload = root["data"] as? [String: Any] ?? root
            for (index, limit) in (payload["limits"] as? [[String: Any]] ?? []).enumerated() {
                let type = limit["type"] as? String ?? ""
                guard ["TOKENS_LIMIT", "CREDIT_LIMIT", "TIME_LIMIT"].contains(type) else { continue }
                let remaining: Double?
                if let percent = number(limit["percentage"]), (0...100).contains(percent) {
                    remaining = 1 - percent / 100
                } else if let used = number(limit["currentValue"]), let total = number(limit["usage"]), total > 0, used >= 0 {
                    remaining = max(0, 1 - used / total)
                } else { remaining = nil }
                guard let remaining else { continue }
                let label = glmWindowLabel(limit, type: type)
                windows.append(.init(id: "limit-\(index)", label: label, remainingFraction: remaining,
                                     resetAt: date(limit["nextResetTime"])))
            }
        case .claude, .codex: throw AccountQuotaError.noQuota
        }
        guard !windows.isEmpty else { throw AccountQuotaError.noQuota }
        return AccountQuotaSnapshot(provider: provider, generatedAt: now, windows: windows)
    }

    private static func remaining(_ object: [String: Any]) -> Double? {
        guard let limit = number(object["limit"]), limit > 0 else { return nil }
        if let used = number(object["used"]), used >= 0 { return max(0, 1 - used / limit) }
        if let remaining = number(object["remaining"]), remaining >= 0 { return min(1, remaining / limit) }
        return nil // Missing usage must never become a fabricated 100% remaining.
    }

    private static func kimiWindowLabel(_ raw: Any?) -> String? {
        guard let window = raw as? [String: Any], let duration = number(window["duration"]),
              duration > 0, duration < 1_000_000 else { return nil }
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_MINUTE": return duration.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(duration / 60))h" : "\(Int(duration))m"
        case "TIME_UNIT_HOUR": return "\(Int(duration))h"
        case "TIME_UNIT_DAY": return "\(Int(duration))d"
        case "TIME_UNIT_WEEK": return "\(Int(duration))w"
        default: return nil
        }
    }

    private static func glmWindowLabel(_ limit: [String: Any], type: String) -> String {
        if type == "TIME_LIMIT" { return "Monthly tools" }
        if let count = number(limit["number"]), count > 0, count < 1_000_000 {
            switch number(limit["unit"]) {
            case 3: return "\(Int(count))h"
            case 6: return "\(Int(count))w"
            default: break
            }
        }
        return type == "TOKENS_LIMIT" ? "5h" : "Coding quota"
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountQuotaError.invalidResponse
        }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func fraction(_ value: Any?) -> Double? {
        guard let value = number(value), (0...1).contains(value) else { return nil }
        return value
    }

    private static func date(_ value: Any?) -> Date? {
        if let milliseconds = number(value), milliseconds > 0 {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
