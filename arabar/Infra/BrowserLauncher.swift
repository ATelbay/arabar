import AppKit

/// Opens a provider's web app so the user can refresh an expired session.
///
/// arabar reads usage by scraping the browser's existing login cookies — it is not an OAuth
/// client, so it cannot perform an in-app login. The practical equivalent is to send the user
/// to the provider's site in *the same browser arabar reads cookies from*, so the fresh login
/// updates exactly the cookie store the next refresh will read.
enum BrowserLauncher {
    static func openLogin(for provider: Provider) {
        let urlString = provider == .codex ? "https://chatgpt.com/" : "https://claude.ai/"
        guard let url = URL(string: urlString) else { return }

        let sourceKey = provider == .codex ? "cookies.source.openai" : "cookies.source.claude"
        let source = UserDefaults.standard.string(forKey: sourceKey) ?? "safari"

        let bundleId: String?
        switch source {
        case "chrome": bundleId = "com.google.Chrome"
        case "brave":  bundleId = "com.brave.Browser"
        case "edge":   bundleId = "com.microsoft.edgemac"
        case "safari": bundleId = "com.apple.Safari"
        default:       bundleId = nil
        }

        if let bid = bundleId,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            // Configured browser not installed (or Safari path) — fall back to the default browser.
            NSWorkspace.shared.open(url)
        }
    }
}
