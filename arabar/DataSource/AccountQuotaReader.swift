import Foundation
import CoreFoundation

enum AccountQuotaError: LocalizedError {
    case disabled, missingKey, missingGeminiLogin, missingGeminiClient, credentialsChanged, unauthorized, missingProject, noQuota, invalidResponse
    /// Kimi Code CLI is set up but its short-lived token has expired and no API key is saved.
    case kimiCLITokenExpired
    /// Antigravity (agy) source selected but no saved agy sign-in / OAuth client was found.
    case missingAntigravityLogin, missingAntigravityClient
    case http(Int)

    var invalidatesSnapshot: Bool {
        switch self {
        case .disabled, .missingKey, .missingGeminiLogin, .missingGeminiClient, .credentialsChanged, .unauthorized, .noQuota,
             .missingAntigravityLogin, .missingAntigravityClient: return true
        case .missingProject, .invalidResponse, .http, .kimiCLITokenExpired: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .disabled: return "Connect your account in Settings → Providers."
        case .missingKey: return "Sign in with Kimi Code CLI or add a coding-plan API key in Settings → Providers."
        case .missingAntigravityLogin: return "No Antigravity sign-in found. Run `agy` and sign in with Google, then refresh."
        case .missingAntigravityClient: return "Could not refresh the Antigravity sign-in: the agy executable was not found. Run `agy` once to refresh it."
        case .kimiCLITokenExpired: return "Kimi Code CLI sign-in is idle (its token lasts ~15 min). Run `kimi` to refresh it, or add a Kimi Code API key in Settings → Providers → Kimi."
        case .missingGeminiLogin: return "Sign in with Google in Gemini CLI first. A readable ~/.gemini/oauth_creds.json is required."
        case .missingGeminiClient: return "Could not locate Gemini CLI’s Google login configuration. Install Gemini CLI through npm or Homebrew, then reconnect."
        case .credentialsChanged: return "Gemini CLI sign-in changed while refreshing. Refresh account limits again."
        case .unauthorized: return "Access rejected or expired. Reconnect your account in Settings → Providers."
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
    private let readGeminiCredentials: () throws -> Data
    private let readKimiCLI: () -> KimiCodeCLIAuth?
    private let readKey: (String) -> String?
    private let readAntigravity: () -> AntigravityCredentials?
    private let antigravityClients: () -> [GeminiOAuthClient]
    private let antigravityProject: () -> String?
    private var antigravityToken: (refreshToken: String, token: String, expiresAt: Date)?
    private var antigravityClient: GeminiOAuthClient?
    private var geminiToken: (credentials: Data, token: String, expiresAt: Date)?
    private var geminiRefreshes: [Data: (id: UUID, task: Task<(token: String, expiresAt: Date), Error>)] = [:]

    init(session: URLSession = .shared, readGeminiCredentials: @escaping () throws -> Data = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/oauth_creds.json")
        return try Data(contentsOf: url)
    }, readKimiCLI: @escaping () -> KimiCodeCLIAuth? = { KimiCodeCLIAuth.load() },
         readKey: @escaping (String) -> String? = { KeychainStore.get(account: $0) },
         readAntigravity: @escaping () -> AntigravityCredentials? = { AntigravityAuth.readCredentials() },
         antigravityClients: @escaping () -> [GeminiOAuthClient] = {
             AntigravityAuth.oauthClients(in: AntigravityAuth.binaryURL())
         },
         antigravityProject: @escaping () -> String? = { AntigravityAuth.projectId() }) {
        self.session = session
        self.readGeminiCredentials = readGeminiCredentials
        self.readKimiCLI = readKimiCLI
        self.readKey = readKey
        self.readAntigravity = readAntigravity
        self.antigravityClients = antigravityClients
        self.antigravityProject = antigravityProject
    }

    func fetch(configuration: AccountQuotaConfiguration) async throws -> AccountQuotaSnapshot {
        guard configuration.enabled else { throw AccountQuotaError.disabled }
        switch configuration.provider {
        case .gemini where configuration.source == GeminiQuotaSource.antigravity:
            return try await fetchAntigravity(project: configuration.project)
        case .gemini:
            guard let data = try? readGeminiCredentials() else { throw AccountQuotaError.missingGeminiLogin }
            let snapshot = try await fetchGemini(credentials: data, project: configuration.project)
            // A CLI logout/account switch can happen while the network request is in flight.
            // Never publish that previous login's quota under the current connection.
            guard let current = try? readGeminiCredentials(), current == data else {
                throw AccountQuotaError.credentialsChanged
            }
            return snapshot
        case .kimi:
            let cli = readKimiCLI()
            let key = readKey(configuration.keychainAccount).flatMap { $0.isEmpty ? nil : $0 }
            // Prefer the CLI's live login; a rejected token falls through to the API key.
            if let cli, let token = cli.validToken() {
                do {
                    return try await fetchKimi(baseURL: cli.baseURL, bearer: token)
                } catch AccountQuotaError.unauthorized where key != nil {}
            }
            guard let key else {
                throw cli == nil ? AccountQuotaError.missingKey : AccountQuotaError.kimiCLITokenExpired
            }
            return try await fetchKeyQuota(provider: .kimi, key: key, region: configuration.region)
        case .glm:
            guard let key = readKey(configuration.keychainAccount), !key.isEmpty else {
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
            return try await fetchKimi(
                baseURL: region == "china" ? KimiCodeCLIAuth.mainlandBaseURL : KimiCodeCLIAuth.globalBaseURL,
                bearer: key
            )
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

    private func fetchKimi(baseURL: String, bearer: String) async throws -> AccountQuotaSnapshot {
        let data = try await request(url: baseURL + "/usages", authorization: "Bearer \(bearer)")
        return try Self.parse(data: data, provider: .kimi, now: Date())
    }

    func fetchGemini(credentials: Data, project: String) async throws -> AccountQuotaSnapshot {
        let token = try await googleAccessToken(credentials: credentials)
        do {
            return try await googleQuota(token: token, project: project)
        } catch AccountQuotaError.unauthorized {
            let refreshed = try await googleAccessToken(credentials: credentials, rejectedToken: token)
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

    private func googleAccessToken(credentials: Data, rejectedToken: String? = nil) async throws -> String {
        if let cached = geminiToken, cached.credentials == credentials,
           cached.token != rejectedToken, cached.expiresAt.timeIntervalSinceNow > 60 { return cached.token }
        guard let object = try? Self.object(credentials) else { throw AccountQuotaError.missingGeminiLogin }
        if rejectedToken == nil, let token = object["access_token"] as? String, !token.isEmpty,
           let expiry = Self.number(object["expiry_date"]), expiry / 1000 > Date().timeIntervalSince1970 + 60 {
            return token
        }
        // Actors are reentrant at network awaits. Share refreshes for the same login,
        // including callers whose old-token rejection arrives after a refresh started.
        let refresh: (id: UUID, task: Task<(token: String, expiresAt: Date), Error>)
        if let pending = geminiRefreshes[credentials] {
            refresh = pending
        } else {
            refresh = (UUID(), Task { try await self.refreshGoogleToken(credentials: credentials) })
            geminiRefreshes[credentials] = refresh
        }
        do {
            let result = try await refresh.task.value
            if geminiRefreshes[credentials]?.id == refresh.id {
                geminiRefreshes[credentials] = nil
                geminiToken = (credentials, result.token, result.expiresAt)
            }
            return result.token
        } catch {
            if geminiRefreshes[credentials]?.id == refresh.id { geminiRefreshes[credentials] = nil }
            throw error
        }
    }

    // MARK: - Antigravity (agy)

    private func fetchAntigravity(project: String) async throws -> AccountQuotaSnapshot {
        guard let credentials = readAntigravity() else { throw AccountQuotaError.missingAntigravityLogin }
        let explicitProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectID = explicitProject.isEmpty ? antigravityProject() : explicitProject
        let token = try await antigravityAccessToken(credentials)
        do {
            return try await antigravityQuota(token: token, project: projectID)
        } catch AccountQuotaError.unauthorized {
            let refreshed = try await antigravityAccessToken(credentials, rejectedToken: token)
            return try await antigravityQuota(token: refreshed, project: projectID)
        }
    }

    /// agy's own model quotas; falls back to the Code Assist bucket report for the same
    /// project if the model list carries no quota information.
    private func antigravityQuota(token: String, project: String?) async throws -> AccountQuotaSnapshot {
        let body: [String: Any] = project.map { ["project": $0] } ?? [:]
        let models = try await request(url: AntigravityAuth.quotaBaseURL + "fetchAvailableModels",
                                       authorization: "Bearer \(token)", body: body)
        let windows = try Self.parseAntigravityModels(data: models)
        if !windows.isEmpty {
            return AccountQuotaSnapshot(provider: .gemini, generatedAt: Date(), windows: windows)
        }
        guard let project else { throw AccountQuotaError.noQuota }
        let buckets = try await request(url: AntigravityAuth.quotaBaseURL + "retrieveUserQuota",
                                        authorization: "Bearer \(token)", body: ["project": project, "userAgent": "arabar"])
        return try Self.parse(data: buckets, provider: .gemini, now: Date())
    }

    private func antigravityAccessToken(_ credentials: AntigravityCredentials, rejectedToken: String? = nil) async throws -> String {
        if rejectedToken == nil, let token = credentials.validAccessToken() { return token }
        guard let refreshToken = credentials.refreshToken else { throw AccountQuotaError.missingAntigravityLogin }
        if let cached = antigravityToken, cached.refreshToken == refreshToken, cached.token != rejectedToken,
           cached.expiresAt.timeIntervalSinceNow > 60 {
            return cached.token
        }
        // The client that issued agy's token is unknown up front; try the remembered one,
        // then any stored alongside the token, then every pair found in the agy executable.
        var candidates: [GeminiOAuthClient] = [antigravityClient, credentials.client].compactMap { $0 }
        if candidates.isEmpty { candidates = antigravityClients() }
        guard !candidates.isEmpty else { throw AccountQuotaError.missingAntigravityClient }
        for client in candidates {
            guard let data = try? await request(url: "https://oauth2.googleapis.com/token", authorization: nil, body: [
                "grant_type": "refresh_token", "refresh_token": refreshToken,
                "client_id": client.id, "client_secret": client.secret
            ], formEncoded: true),
                let response = try? Self.object(data),
                let token = response["access_token"] as? String, !token.isEmpty,
                let lifetime = Self.number(response["expires_in"]), lifetime > 0 else { continue }
            antigravityClient = client
            antigravityToken = (refreshToken, token, Date().addingTimeInterval(lifetime))
            return token
        }
        // A remembered client that stopped working: retry the full list once.
        if antigravityClient != nil {
            antigravityClient = nil
            return try await antigravityAccessToken(credentials, rejectedToken: rejectedToken)
        }
        throw AccountQuotaError.unauthorized
    }

    /// Tolerant reader for `fetchAvailableModels`: any object carrying `quotaInfo` is one
    /// quota row, labelled by its display name, model id or map key. In proto3 JSON a zero
    /// `remainingFraction` is omitted, so a quotaInfo without it means an exhausted quota.
    static func parseAntigravityModels(data: Data) throws -> [AccountQuotaWindow] {
        let root = try object(data)
        var windows: [AccountQuotaWindow] = []
        var seen: Set<String> = []
        func visit(_ value: Any, key: String?) {
            if let dict = value as? [String: Any] {
                if let quota = dict["quotaInfo"] as? [String: Any] {
                    let remaining = quota["remainingFraction"] == nil ? 0 : fraction(quota["remainingFraction"])
                    let label = (dict["displayName"] as? String) ?? (dict["modelId"] as? String)
                        ?? (dict["model"] as? String) ?? key ?? "Model quota"
                    let id = "agy-" + ((dict["modelId"] as? String) ?? key ?? label)
                    if let remaining, seen.insert(id).inserted {
                        windows.append(.init(id: id, label: label, remainingFraction: remaining,
                                             resetAt: date(quota["resetTime"])))
                    }
                    return
                }
                for (childKey, child) in dict { visit(child, key: childKey) }
            } else if let array = value as? [Any] {
                for element in array { visit(element, key: nil) }
            }
        }
        visit(root, key: nil)
        return windows.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private func refreshGoogleToken(credentials: Data) async throws -> (token: String, expiresAt: Date) {
        let object = try Self.object(credentials)
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
        return (token, Date().addingTimeInterval(lifetime))
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
            // Current Kimi Code shape (kimi-code managed-usage.ts):
            // { usages: { limit_5h: { used_ratio, reset_time }, limit_7d, limit_month_total, limit_month_code } }
            if let usages = root["usages"] as? [String: Any] {
                let entries = [("limit_5h", "5h"), ("limit_7d", "Weekly"),
                               ("limit_month_total", "Monthly total"), ("limit_month_code", "Monthly code")]
                for (key, label) in entries {
                    guard let entry = usages[key] as? [String: Any],
                          let used = fraction(entry["used_ratio"]) else { continue }
                    windows.append(.init(id: key, label: label, remainingFraction: 1 - used,
                                         resetAt: date(entry["reset_time"])))
                }
            }
            // Legacy kimi-cli shape: { usage: {...}, limits: [...] }. The live API returns both
            // shapes for the same quotas, so read it only when the current shape had nothing.
            guard windows.isEmpty else { break }
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
