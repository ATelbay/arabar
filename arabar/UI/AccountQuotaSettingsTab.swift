import SwiftUI

/// Settings page for providers whose limits come straight from the provider's quota API
/// (Gemini, Kimi, GLM). Shown inside Settings → Providers.
struct AccountQuotaSettingsPage: View {
    let provider: Provider
    @AppStorage private var enabled: Bool
    @AppStorage private var region: String
    @AppStorage private var project: String
    @AppStorage private var revision: Int
    @AppStorage private var geminiSource: String
    @State private var agyLoginFound: Bool?
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var status = ""
    @State private var testing = false
    @State private var kimiCLI: KimiCodeCLIAuth?

    init(provider: Provider) {
        self.provider = provider
        let prefix = "quota.\(provider.rawValue)"
        _enabled = AppStorage(wrappedValue: false, "\(prefix).enabled")
        _region = AppStorage(wrappedValue: "global", "\(prefix).region")
        _project = AppStorage(wrappedValue: "", "\(prefix).project")
        _revision = AppStorage(wrappedValue: 0, "\(prefix).revision")
        _geminiSource = AppStorage(wrappedValue: GeminiQuotaSource.cli, "\(prefix).source")
    }

    private var account: String { "quota.key.\(provider.rawValue)" }

    var body: some View {
        Form {
            MenuBarVisibilitySection(provider: provider)

            Section {
                Toggle("Read account limits", isOn: $enabled)
                Button(testing ? "Checking…" : "Test connection") { testConnection() }
                    .disabled(!enabled || testing)
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Connection")
            }

            switch provider {
            case .gemini: geminiSections
            case .kimi:
                kimiCLISection
                apiKeySection
            default: apiKeySection
            }

            Section {
                Text(privacyNote).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasKey = KeychainStore.has(account: account)
            if provider == .kimi { kimiCLI = KimiCodeCLIAuth.load() }
            if provider == .gemini { checkAntigravityLogin() }
        }
        .onChange(of: enabled) { _, value in
            status = ""
            if value { UserDefaults.standard.set(true, forKey: provider.menuBarVisibilityKey) }
        }
        .onChange(of: region) { _, _ in status = "" }
        .onChange(of: project) { _, _ in status = "" }
        .onChange(of: geminiSource) { _, _ in status = "" }
    }

    // MARK: - Gemini

    @ViewBuilder
    private var geminiSections: some View {
        Section {
            Picker("Source", selection: $geminiSource) {
                Text("Gemini CLI").tag(GeminiQuotaSource.cli)
                Text("Antigravity (agy)").tag(GeminiQuotaSource.antigravity)
            }
            .pickerStyle(.segmented)
            if geminiSource == GeminiQuotaSource.antigravity {
                HStack(alignment: .top) {
                    Image(systemName: agyLoginFound == true ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(agyLoginFound == true ? .green : .secondary)
                    Text(agyStatusText).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Recheck") { checkAntigravityLogin() }
                }
                Text("Shows the per-model quotas Antigravity uses. arabar reads agy's saved Google sign-in from the Keychain (read-only) and refreshes the access token in memory; agy stays signed in. Token usage and cost are not available: agy does not log them locally.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Install Gemini CLI (npm or Homebrew) and sign in with Google once. arabar reads ~/.gemini/oauth_creds.json and never changes it.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Google Cloud project ID (optional)", text: $project)
                .textFieldStyle(.roundedBorder)
            Text(geminiSource == GeminiQuotaSource.antigravity
                 ? "Leave empty to use the project agy selected."
                 : "Detected automatically when possible. Gemini API keys are not used by this connection.")
                .font(.caption).foregroundColor(.secondary)
        } header: {
            Text("Sign-in")
        }
    }

    private var agyStatusText: String {
        switch agyLoginFound {
        case .none: return "Checking…"
        case .some(false): return "No agy sign-in found. Install Antigravity CLI and run `agy` to sign in with Google."
        case .some(true):
            let project = AntigravityAuth.projectId().map { " · project \($0)" } ?? ""
            return "Signed in to agy\(project)"
        }
    }

    private func checkAntigravityLogin() {
        agyLoginFound = nil
        Task.detached {
            let found = AntigravityAuth.hasSavedLogin()
            await MainActor.run { agyLoginFound = found }
        }
    }

    // MARK: - Kimi

    @ViewBuilder
    private var kimiCLISection: some View {
        Section {
            HStack(alignment: .top) {
                Image(systemName: kimiCLIStatus.symbol).foregroundColor(kimiCLIStatus.color)
                Text(kimiCLIStatus.text).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Recheck") { kimiCLI = KimiCodeCLIAuth.load() }
            }
            Text("Kimi rotates sign-in tokens, so arabar only reads the CLI's current token and never refreshes it (refreshing would sign the CLI out). The token lasts about 15 minutes after the CLI was last used; add an API key below to keep limits visible in between.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Kimi Code CLI sign-in")
        }
    }

    private var kimiCLIStatus: (text: String, symbol: String, color: Color) {
        guard let cli = kimiCLI else {
            return ("Kimi Code CLI not found. Install it and run `kimi` to sign in, or use an API key.",
                    "xmark.circle", .secondary)
        }
        if cli.validToken() != nil {
            return ("Signed in · \(cli.host) · active", "checkmark.circle.fill", .green)
        }
        return ("Signed in · \(cli.host) · idle — token expired. Run `kimi` to refresh it.",
                "clock.badge.exclamationmark", .orange)
    }

    // MARK: - API key (Kimi fallback, GLM primary)

    @ViewBuilder
    private var apiKeySection: some View {
        Section {
            Picker(provider == .kimi ? "Key region" : "Account region", selection: $region) {
                Text(provider == .kimi ? "kimi.ai (international)" : "Z.ai").tag("global")
                Text(provider == .kimi ? "kimi.com" : "Zhipu (bigmodel.cn)").tag("china")
            }
            if let mismatch = regionMismatchWarning {
                Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField("Coding-plan API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            if hasKey { Text("Key saved in Keychain").font(.caption).foregroundColor(.secondary) }
            HStack {
                Button("Save key") {
                    do {
                        try KeychainStore.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: account)
                        apiKey = ""
                        hasKey = true
                        revision &+= 1
                        status = "Saved"
                    } catch {
                        status = "Could not save the key in Keychain. Please try again."
                    }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                Button("Clear key") {
                    if KeychainStore.delete(account: account) {
                        apiKey = ""
                        hasKey = false
                        // Kimi can keep working through the CLI sign-in without a key.
                        if provider != .kimi || kimiCLI == nil { enabled = false }
                        revision &+= 1
                        status = "Key removed"
                    } else { status = "Could not remove the key from Keychain." }
                }
                .disabled(!hasKey || testing)
            }
            Text(provider == .kimi
                 ? "A Kimi Code key from your account's Code console. Shows the 5h, weekly and monthly coding limits Kimi returns."
                 : "A GLM Coding Plan key. Shows the coding and tool quota windows returned by Z.ai or Zhipu.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(provider == .kimi ? "API key (fallback)" : "API key")
        }
    }

    /// The CLI config tells us which Kimi site the account lives on; a key for the other
    /// site is rejected, which previously showed up only as a vague connection error.
    private var regionMismatchWarning: String? {
        guard provider == .kimi, let cli = kimiCLI else { return nil }
        let cliIsGlobal = cli.host.hasSuffix("kimi.ai")
        guard cliIsGlobal != (region == "global") else { return nil }
        return "Your Kimi Code CLI signs in to \(cli.host). Choose \(cliIsGlobal ? "kimi.ai" : "kimi.com") unless this key is from the other site."
    }

    private var privacyNote: String {
        switch provider {
        case .gemini:
            return "Credentials go only to Google's authentication and Code Assist services. The Gemini CLI file and the agy Keychain item are never changed."
        case .kimi:
            return "The CLI token and API key go only to Kimi's quota endpoint. Keys stay in the macOS Keychain; the CLI files are never changed."
        default:
            return "Keys stay in the macOS Keychain and are sent only to the selected provider's quota endpoint."
        }
    }

    private func testConnection() {
        let configuration = AccountQuotaConfiguration.load(provider: provider)
        testing = true
        status = ""
        if provider == .kimi { kimiCLI = KimiCodeCLIAuth.load() }
        Task {
            defer { testing = false }
            do {
                let snapshot = try await AccountQuotaReader().fetch(configuration: configuration)
                guard AccountQuotaConfiguration.load(provider: provider) == configuration else { return }
                status = "Connected · " + snapshot.windows.map {
                    "\($0.label) \(Int(($0.remainingFraction * 100).rounded()))% left"
                }.joined(separator: " · ")
            } catch {
                guard AccountQuotaConfiguration.load(provider: provider) == configuration else { return }
                status = error.localizedDescription
            }
        }
    }
}
