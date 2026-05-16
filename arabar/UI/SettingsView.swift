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

// MARK: - Claude Tab

struct ClaudeSettingsTab: View {
    // Cookies
    @AppStorage("cookies.enabled.claude") private var cookiesEnabled: Bool = false
    @AppStorage("cookies.source.claude") private var browserSource: String = "safari"
    @State private var cookiesStatus: String = ""
    @State private var cookiesTesting: Bool = false
    @State private var claudeCookieExpiry: String? = nil

    // Admin API key
    @State private var apiKey: String = ""
    @State private var apiKeyHasValue: Bool = false
    @State private var apiStatus: String = ""
    @State private var apiTesting: Bool = false

    // Display preference
    @AppStorage("display.source.claude") private var displaySource: String = "subscription"

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
                            cookiesStatus = await ClaudeCookiesReader().testConnection()
                            claudeCookieExpiry = cookieExpiryStatus(
                                for: browserSource,
                                hosts: ["claude.ai"],
                                cookieName: "sessionKey"
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

                // Cookie expiry row (Safari only, shown after Test)
                if let expiry = claudeCookieExpiry {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .foregroundColor(expiryColor(expiry))
                        Text(expiry)
                            .font(.caption)
                            .foregroundColor(expiryColor(expiry))
                    }
                }

                Text("Cookies are read locally and used only for requests to claude.ai. They are never sent to third parties.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            } header: {
                Text("Subscription (browser cookies)")
            }

            // ── Admin API ────────────────────────────────────────────────
            Section {
                SecureField("sk-ant-admin-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                // Green saved indicator: visible when key is stored and user hasn't started typing a new one
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
                        try? KeychainStore.set(apiKey, for: KeychainAccount.anthropicAdminKey)
                        apiKey = ""
                        apiKeyHasValue = true
                        apiStatus = "Saved"
                    }
                    .disabled(apiKey.isEmpty)

                    Button("Clear") {
                        KeychainStore.delete(account: KeychainAccount.anthropicAdminKey)
                        apiKey = ""
                        apiKeyHasValue = false
                        apiStatus = ""
                    }
                    .disabled(!apiKeyHasValue)

                    Button("Test connection") {
                        Task {
                            apiTesting = true
                            apiStatus = await AnthropicAdminAPIReader().testConnection()
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

                Link("Create Admin key at console.anthropic.com →",
                     destination: URL(string: "https://console.anthropic.com/settings/admin-keys")!)
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
            apiKeyHasValue = KeychainStore.has(account: KeychainAccount.anthropicAdminKey)
        }
    }
}

// MARK: - OpenAI Tab

struct OpenAISettingsTab: View {
    // Cookies
    @AppStorage("cookies.enabled.openai") private var cookiesEnabled: Bool = false
    @AppStorage("cookies.source.openai") private var browserSource: String = "safari"
    @State private var cookiesStatus: String = ""
    @State private var cookiesTesting: Bool = false
    @State private var openaiCookieExpiry: String? = nil

    // Admin API key
    @State private var apiKey: String = ""
    @State private var apiKeyHasValue: Bool = false
    @State private var apiStatus: String = ""
    @State private var apiTesting: Bool = false

    // Display preference
    @AppStorage("display.source.openai") private var displaySource: String = "subscription"

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
                            cookiesStatus = await OpenAICookiesReader().testConnection()
                            openaiCookieExpiry = cookieExpiryStatus(
                                for: browserSource,
                                hosts: ["chatgpt.com"],
                                cookieName: "__Secure-next-auth.session-token"
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

                // Cookie expiry row (Safari only, shown after Test)
                if let expiry = openaiCookieExpiry {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .foregroundColor(expiryColor(expiry))
                        Text(expiry)
                            .font(.caption)
                            .foregroundColor(expiryColor(expiry))
                    }
                }

                Text("Cookies are read locally and used only for requests to chatgpt.com. They are never sent to third parties.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            } header: {
                Text("Subscription (browser cookies)")
            }

            // ── Admin API ────────────────────────────────────────────────
            Section {
                SecureField("sk-admin-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                // Green saved indicator: visible when key is stored and user hasn't started typing a new one
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
                        try? KeychainStore.set(apiKey, for: KeychainAccount.openaiAdminKey)
                        apiKey = ""
                        apiKeyHasValue = true
                        apiStatus = "Saved"
                    }
                    .disabled(apiKey.isEmpty)

                    Button("Clear") {
                        KeychainStore.delete(account: KeychainAccount.openaiAdminKey)
                        apiKey = ""
                        apiKeyHasValue = false
                        apiStatus = ""
                    }
                    .disabled(!apiKeyHasValue)

                    Button("Test connection") {
                        Task {
                            apiTesting = true
                            apiStatus = await OpenAIUsageAPIReader().testConnection()
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

                Link("Create Admin key at platform.openai.com →",
                     destination: URL(string: "https://platform.openai.com/settings/organization/admin-keys")!)
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
            apiKeyHasValue = KeychainStore.has(account: KeychainAccount.openaiAdminKey)
        }
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
