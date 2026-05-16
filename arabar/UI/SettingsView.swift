import SwiftUI

// MARK: - Cookie expiry helpers (best-effort, never throws)

private func cookieExpiryDate(for browser: String, hosts: [String], cookieName: String) -> Date? {
    let source = BrowserSource(rawValue: browser) ?? .safari
    switch source {
    case .safari:
        guard let cookies = try? SafariBinaryCookies.readCookies(matching: hosts) else { return nil }
        return cookies.first(where: { $0.name == cookieName })?.expiry
    case .chrome, .brave, .edge:
        return ChromiumCookieDB.cookieExpiry(browser: source, cookieName: cookieName, hosts: hosts)
    }
}

private func cookieExpiryStatus(for browser: String, hosts: [String], cookieName: String) -> String? {
    guard let expiry = cookieExpiryDate(for: browser, hosts: hosts, cookieName: cookieName) else { return nil }
    return expiryStatusString(from: expiry)
}

private func expiryStatusString(from expiry: Date) -> String {
    let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
    if days < 0 {
        let ago = abs(days)
        return ago == 1 ? "Expired yesterday" : "Expired \(ago) days ago"
    } else if days == 0 {
        return "Expires today"
    } else {
        return "Expires in \(days) day\(days == 1 ? "" : "s")"
    }
}

private func expiryColor(_ status: String) -> Color {
    if status.hasPrefix("Expired") { return .red }
    // "Expires today" or "Expires in 1 day" / "Expires in 2 days"
    if status == "Expires today" { return .orange }
    if let days = status.components(separatedBy: " ").compactMap({ Int($0) }).first, days < 3 {
        return .orange
    }
    return .secondary
}

// MARK: - Root

struct SettingsView: View {
    var body: some View {
        TabView {
            ClaudeSettingsTab()
                .tabItem { Label("Claude", systemImage: "brain") }
            OpenAISettingsTab()
                .tabItem { Label("ChatGPT", systemImage: "bubble.left") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 560)
    }
}

// MARK: - Provider tab config

private struct ProviderTabConfig {
    let cookiesEnabledKey: String
    let cookiesSourceKey: String
    let displaySourceKey: String
    let apiKeyAccount: String
    let cookieHosts: [String]
    let cookieName: String
    let apiKeyPlaceholder: String
    let consoleURL: URL
    let cookiesPrivacyNote: String
    let testCookies: () async -> String
    let testAPI: () async -> String
}

extension ProviderTabConfig {
    static let claude = ProviderTabConfig(
        cookiesEnabledKey:  "cookies.enabled.claude",
        cookiesSourceKey:   "cookies.source.claude",
        displaySourceKey:   "display.source.claude",
        apiKeyAccount:      KeychainAccount.anthropicAdminKey,
        cookieHosts:        ["claude.ai"],
        cookieName:         "sessionKey",
        apiKeyPlaceholder:  "sk-ant-admin-…",
        consoleURL:         URL(string: "https://console.anthropic.com/settings/admin-keys")!,
        cookiesPrivacyNote: "Cookies are read locally and used only for requests to claude.ai. They are never sent to third parties.",
        testCookies:        { await ClaudeCookiesReader().testConnection() },
        testAPI:            { await AnthropicAdminAPIReader().testConnection() }
    )

    static let openai = ProviderTabConfig(
        cookiesEnabledKey:  "cookies.enabled.openai",
        cookiesSourceKey:   "cookies.source.openai",
        displaySourceKey:   "display.source.openai",
        apiKeyAccount:      KeychainAccount.openaiAdminKey,
        cookieHosts:        ["chatgpt.com"],
        cookieName:         "__Secure-next-auth.session-token",
        apiKeyPlaceholder:  "sk-admin-…",
        consoleURL:         URL(string: "https://platform.openai.com/settings/organization/admin-keys")!,
        cookiesPrivacyNote: "Cookies are read locally and used only for requests to chatgpt.com. They are never sent to third parties.",
        testCookies:        { await OpenAICookiesReader().testConnection() },
        testAPI:            { await OpenAIUsageAPIReader().testConnection() }
    )
}

// MARK: - Shared provider tab

private struct ProviderSettingsTab: View {
    let config: ProviderTabConfig

    @AppStorage private var cookiesEnabled: Bool
    @AppStorage private var browserSource: String
    @AppStorage private var displaySource: String

    @State private var cookiesStatus: String = ""
    @State private var cookiesTesting: Bool = false
    @State private var cookieExpiry: String? = nil

    @State private var apiKey: String = ""
    @State private var apiKeyHasValue: Bool = false
    @State private var apiStatus: String = ""
    @State private var apiTesting: Bool = false

    init(config: ProviderTabConfig) {
        self.config = config
        self._cookiesEnabled = AppStorage(wrappedValue: false, config.cookiesEnabledKey)
        self._browserSource  = AppStorage(wrappedValue: "safari", config.cookiesSourceKey)
        self._displaySource  = AppStorage(wrappedValue: "subscription", config.displaySourceKey)
    }

    var body: some View {
        Form {
            // ── Subscription (browser cookies) ──────────────────────────
            Section {
                Toggle("Use browser session cookies", isOn: $cookiesEnabled)

                if cookiesEnabled {
                    Picker("Browser", selection: $browserSource) {
                        Text("Safari").tag("safari")
                        Text("Chrome").tag("chrome")
                        Text("Brave").tag("brave")
                        Text("Edge").tag("edge")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                }

                HStack(spacing: 8) {
                    Button("Test connection") {
                        Task {
                            cookiesTesting = true
                            cookiesStatus = await config.testCookies()
                            cookieExpiry = cookieExpiryStatus(
                                for: browserSource,
                                hosts: config.cookieHosts,
                                cookieName: config.cookieName
                            )
                            cookiesTesting = false
                        }
                    }
                    .disabled(!cookiesEnabled || cookiesTesting)

                    if cookiesTesting {
                        ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    }

                    if !cookiesStatus.isEmpty {
                        Text(cookiesStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let expiry = cookieExpiry {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .foregroundColor(expiryColor(expiry))
                        Text(expiry)
                            .font(.caption)
                            .foregroundColor(expiryColor(expiry))
                    }
                }

                Text(config.cookiesPrivacyNote)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            } header: {
                Text("Subscription (browser cookies)")
            }

            // ── Admin API ────────────────────────────────────────────────
            Section {
                SecureField(config.apiKeyPlaceholder, text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                if apiKeyHasValue && apiKey.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("API key saved in Keychain")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button("Save") {
                        try? KeychainStore.set(apiKey, for: config.apiKeyAccount)
                        apiKey = ""
                        apiKeyHasValue = true
                        apiStatus = "Saved"
                    }
                    .disabled(apiKey.isEmpty)

                    Button("Clear") {
                        KeychainStore.delete(account: config.apiKeyAccount)
                        apiKey = ""
                        apiKeyHasValue = false
                        apiStatus = ""
                    }
                    .disabled(!apiKeyHasValue)

                    Button("Test connection") {
                        Task {
                            apiTesting = true
                            apiStatus = await config.testAPI()
                            apiTesting = false
                        }
                    }
                    .disabled(!apiKeyHasValue || apiTesting)

                    if apiTesting {
                        ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    }
                }

                if !apiStatus.isEmpty {
                    Text(apiStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Link("Create Admin key at \(config.consoleURL.host ?? "") →",
                     destination: config.consoleURL)
                    .font(.caption)

            } header: {
                Text("API tier (pay-as-you-go)")
            }

            // ── Display preference ───────────────────────────────────────
            Section {
                Picker("Show in menubar", selection: $displaySource) {
                    Text("Subscription").tag("subscription")
                    Text("API tier").tag("api")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("Choose which source drives the menubar display.")
                    .font(.caption)
                    .foregroundColor(.secondary)

            } header: {
                Text("Display in menubar")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            apiKeyHasValue = KeychainStore.has(account: config.apiKeyAccount)
        }
    }
}

// MARK: - Claude Tab

struct ClaudeSettingsTab: View {
    var body: some View { ProviderSettingsTab(config: .claude) }
}

// MARK: - OpenAI Tab

struct OpenAISettingsTab: View {
    var body: some View { ProviderSettingsTab(config: .openai) }
}

// MARK: - About Tab

struct AboutTab: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("arabar")
                .font(.title)
                .fontWeight(.semibold)

            Text("Version \(appVersion)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Menubar usage monitor for Claude and ChatGPT.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 320)

            Spacer()
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
