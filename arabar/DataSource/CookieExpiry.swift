import Foundation

enum CookieExpiry {

    /// Returns the configured browser's stored expiry for the provider's session cookie.
    /// Reads selected browser from UserDefaults. Never throws.
    static func forProvider(_ provider: Provider) -> Date? {
        let (browserKey, cookieName, fallbackCookieName, hosts): (String, String, String?, [String])
        switch provider {
        case .claude:
            browserKey = "cookies.source.claude"
            cookieName = "sessionKey"
            fallbackCookieName = nil
            hosts = ["claude.ai", ".claude.ai"]
        case .codex:
            browserKey = "cookies.source.openai"
            cookieName = "__Secure-next-auth.session-token.0"
            fallbackCookieName = "__Secure-next-auth.session-token"
            hosts = ["chatgpt.com", ".chatgpt.com"]
        }

        let browserRaw = UserDefaults.standard.string(forKey: browserKey) ?? "safari"
        let browser = BrowserSource(rawValue: browserRaw) ?? .safari

        switch browser {
        case .safari:
            return safariExpiry(cookieName: cookieName, fallback: fallbackCookieName, hosts: hosts)
        case .chrome, .brave, .edge:
            if let expiry = ChromiumCookieDB.cookieExpiry(browser: browser, cookieName: cookieName, hosts: hosts) {
                return expiry
            }
            if let fallback = fallbackCookieName {
                return ChromiumCookieDB.cookieExpiry(browser: browser, cookieName: fallback, hosts: hosts)
            }
            return nil
        }
    }

    // MARK: - Safari

    private static func safariExpiry(cookieName: String, fallback: String?, hosts: [String]) -> Date? {
        guard let cookies = try? SafariBinaryCookies.readCookies(matching: hosts) else { return nil }
        if let cookie = cookies.first(where: { $0.name == cookieName }), let expiry = cookie.expiry {
            return expiry
        }
        if let fallback = fallback,
           let cookie = cookies.first(where: { $0.name == fallback }),
           let expiry = cookie.expiry {
            return expiry
        }
        return nil
    }
}
