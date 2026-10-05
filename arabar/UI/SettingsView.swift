import SwiftUI

// MARK: - Cookie expiry helpers (best-effort, never throws)

private func cookieExpiryDate(for browser: String, hosts: [String], cookieName: String) -> Date? {
    let source = BrowserSource(rawValue: browser) ?? .safari
    switch source {
    case .safari:
        guard let cookies = try? SafariBinaryCookies.readCookies(matching: hosts) else { return nil }
        return cookies.first(where: { $0.name == cookieName || $0.name == cookieName + ".0" })?.expiry
    case .chrome, .brave, .edge:
        return ChromiumCookieDB.cookieExpiry(browser: source, cookieName: cookieName, hosts: hosts)
            ?? ChromiumCookieDB.cookieExpiry(browser: source, cookieName: cookieName + ".0", hosts: hosts)
    }
}

private func cookieExpiryStatus(for browser: String, hosts: [String], cookieName: String) -> String? {
    guard let expiry = cookieExpiryDate(for: browser, hosts: hosts, cookieName: cookieName) else { return nil }
    return expiryStatusString(from: expiry)
}

private func expiryStatusString(from expiry: Date) -> String {
    let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
    if expiry <= Date() {
        if days == 0 { return "Expired today" }
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

/// One "Providers" group with a page per provider: visibility, data source and connection
/// live together instead of being split across Display / per-provider / Account limits tabs.
struct SettingsView: View {
    private enum Page: Hashable {
        case provider(Provider)
        case about
    }

    @State private var selection: Page = .provider(.claude)

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.headline)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)

                Text("Providers")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)

                ForEach(Provider.allCases, id: \.self) { provider in
                    sidebarButton(.provider(provider)) {
                        ProviderSidebarLabel(provider: provider, isSelected: selection == .provider(provider))
                    }
                }

                Divider().padding(.vertical, 8)

                sidebarButton(.about) {
                    Label("About", systemImage: "info.circle")
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 190)
            .frame(maxHeight: .infinity)
            .background(.thinMaterial)

            Divider()

            Group {
                switch selection {
                case .provider(let provider): ProviderSettingsPage(provider: provider).id(provider)
                case .about: AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 600)
    }

    private func sidebarButton<Content: View>(_ page: Page, @ViewBuilder label: () -> Content) -> some View {
        Button {
            selection = page
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == page ? Color.white : Color.primary)
        .background(selection == page ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .accessibilityAddTraits(selection == page ? .isSelected : [])
    }
}

// MARK: - Provider visibility

extension Provider {
    /// UserDefaults key read by the menu bar label and dropdown.
    var menuBarVisibilityKey: String {
        self == .codex ? "display.provider.openai" : "display.provider.\(rawValue)"
    }

    var visibleByDefault: Bool { !usesAccountQuota }

    /// One line on where this provider's numbers come from.
    var dataSourceSummary: String {
        switch self {
        case .claude:
            return "Limit % comes from your claude.ai browser session. Local Claude Code and Pi logs add tokens and cost."
        case .codex:
            return "Limit % comes from your chatgpt.com browser session. Local Codex CLI and Pi logs add tokens and cost."
        case .gemini:
            return "Model quotas from Google, using your Gemini CLI or Antigravity (agy) sign-in. gemini.google.com chat limits are not available."
        case .kimi:
            return "Kimi Code quotas, using your Kimi Code CLI sign-in while it is active, or a Kimi Code API key."
        case .glm:
            return "GLM Coding Plan quotas from Z.ai or Zhipu, using a Coding Plan API key."
        }
    }
}

private struct ProviderSidebarLabel: View {
    let provider: Provider
    let isSelected: Bool
    @AppStorage private var visible: Bool

    init(provider: Provider, isSelected: Bool) {
        self.provider = provider
        self.isSelected = isSelected
        _visible = AppStorage(wrappedValue: provider.visibleByDefault, provider.menuBarVisibilityKey)
    }

    var body: some View {
        HStack {
            Label(provider.displayName, systemImage: provider.symbolName)
            Spacer()
            if visible {
                Image(systemName: "menubar.rectangle")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .help("Shown in the menu bar")
            }
        }
    }
}

/// First section of every provider page.
struct MenuBarVisibilitySection: View {
    let provider: Provider
    @AppStorage private var visible: Bool

    init(provider: Provider) {
        self.provider = provider
        _visible = AppStorage(wrappedValue: provider.visibleByDefault, provider.menuBarVisibilityKey)
    }

    var body: some View {
        Section {
            Toggle("Show in menu bar and menu", isOn: $visible)
        } header: {
            Text("Display")
        } footer: {
            Text("Shown providers rotate in the menu bar every 30 seconds; right-click the icon to switch. Hidden providers stay configured.")
        }
    }
}

private struct ProviderSettingsPage: View {
    let provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: provider.symbolName)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName).font(.title3.weight(.semibold))
                    Text(provider.dataSourceSummary)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.horizontal, .top], 20)

            switch provider {
            case .claude: ProviderSettingsTab(config: .claude)
            case .codex: ProviderSettingsTab(config: .openai)
            case .gemini, .kimi, .glm: AccountQuotaSettingsPage(provider: provider)
            }
        }
    }
}

// MARK: - Provider tab config

private struct ProviderTabConfig {
    let provider: Provider
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
        provider:           .claude,
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
        provider:           .codex,
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
            MenuBarVisibilitySection(provider: config.provider)

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
                            let testedSource = browserSource
                            let result = await config.testCookies()
                            let hosts = config.cookieHosts
                            let name = config.cookieName
                            let expiry = await Task.detached {
                                cookieExpiryStatus(for: testedSource, hosts: hosts, cookieName: name)
                            }.value
                            if cookiesEnabled && browserSource == testedSource {
                                cookiesStatus = result
                                cookieExpiry = expiry
                            }
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
                        do {
                            try KeychainStore.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: config.apiKeyAccount)
                            apiKey = ""
                            apiKeyHasValue = true
                            apiStatus = "Saved"
                            notifyAPIKeyChanged()
                        } catch {
                            apiStatus = "Could not save key: \(error.localizedDescription)"
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiTesting)

                    Button("Clear") {
                        guard KeychainStore.delete(account: config.apiKeyAccount) else {
                            apiStatus = "Could not remove key from Keychain."
                            return
                        }
                        apiKey = ""
                        apiKeyHasValue = false
                        apiStatus = ""
                        notifyAPIKeyChanged()
                    }
                    .disabled(!apiKeyHasValue || apiTesting)

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
                Picker("Usage source", selection: $displaySource) {
                    Text("Subscription").tag("subscription")
                    Text("API tier").tag("api")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("Choose which source drives this provider's usage display.")
                    .font(.caption)
                    .foregroundColor(.secondary)

            } header: {
                Text("Usage source")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            apiKeyHasValue = KeychainStore.has(account: config.apiKeyAccount)
        }
        .onChange(of: browserSource) { _, _ in
            cookiesStatus = ""
            cookieExpiry = nil
        }
        .onChange(of: cookiesEnabled) { _, _ in
            cookiesStatus = ""
            cookieExpiry = nil
        }
    }

    private func notifyAPIKeyChanged() {
        let key = "\(config.apiKeyAccount).revision"
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) &+ 1, forKey: key)
    }
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

            Text("Menubar usage monitor for Claude, ChatGPT, Gemini, Kimi, and GLM.")
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
