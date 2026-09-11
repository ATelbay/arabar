import SwiftUI

struct AccountQuotaSettingsTab: View {
    @State private var provider: Provider = .gemini

    var body: some View {
        VStack {
            Picker("Provider", selection: $provider) {
                ForEach(Provider.accountQuotaProviders, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])
            AccountQuotaConnectionView(provider: provider).id(provider)
        }
    }
}

private struct AccountQuotaConnectionView: View {
    let provider: Provider
    @AppStorage private var enabled: Bool
    @AppStorage private var region: String
    @AppStorage private var project: String
    @AppStorage private var revision: Int
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var status = ""
    @State private var testing = false

    init(provider: Provider) {
        self.provider = provider
        let prefix = "quota.\(provider.rawValue)"
        _enabled = AppStorage(wrappedValue: false, "\(prefix).enabled")
        _region = AppStorage(wrappedValue: "global", "\(prefix).region")
        _project = AppStorage(wrappedValue: "", "\(prefix).project")
        _revision = AppStorage(wrappedValue: 0, "\(prefix).revision")
    }

    private var account: String { "quota.key.\(provider.rawValue)" }

    var body: some View {
        Form {
            Section("Connection") {
                Toggle("Read account limits", isOn: $enabled)
                if provider == .gemini {
                    Text("Uses your existing Gemini CLI Google sign-in to ask Google for Code Assist quotas. Install Gemini CLI through npm or Homebrew and sign in with Google first.")
                    TextField("Google Cloud project ID (optional)", text: $project)
                        .textFieldStyle(.roundedBorder)
                    Text("The project is detected automatically when possible. Gemini API keys and Gemini website chat limits are not supported by this connection.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Picker("Account region", selection: $region) {
                        Text(provider == .kimi ? "International (kimi.ai)" : "Z.ai").tag("global")
                        Text(provider == .kimi ? "Kimi (kimi.com)" : "Zhipu (bigmodel.cn)").tag("china")
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
                                hasKey = false
                                enabled = false
                                revision &+= 1
                                status = "Key removed"
                            } else { status = "Could not remove the key from Keychain." }
                        }
                        .disabled(!hasKey || testing)
                    }
                    Text(provider == .kimi
                         ? "Use a Kimi Code key from your account’s Code console. Displays the weekly and other coding limits returned by Kimi; the separate Kimi membership monthly quota may not be returned."
                         : "Use a GLM Coding Plan key. Displays the coding and tool quota windows returned by Z.ai or Zhipu.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Button(testing ? "Checking…" : "Test connection") {
                    let configuration = AccountQuotaConfiguration.load(provider: provider)
                    testing = true
                    status = ""
                    Task {
                        defer { testing = false }
                        do {
                            let snapshot = try await AccountQuotaReader().fetch(configuration: configuration)
                            guard AccountQuotaConfiguration.load(provider: provider) == configuration else { return }
                            status = "Connected · \(snapshot.windows.count) quota window(s) returned"
                        } catch {
                            guard AccountQuotaConfiguration.load(provider: provider) == configuration else { return }
                            status = error.localizedDescription
                        }
                    }
                }
                .disabled(!enabled || testing)
                if !status.isEmpty { Text(status).font(.caption).foregroundColor(.secondary) }
            }
            Section {
                Text("Shows remaining account quota and reset times. No local usage logs are read for these providers.")
                Text(provider == .gemini
                     ? "Reads ~/.gemini/oauth_creds.json only when enabled. Credentials go only to Google’s authentication and Code Assist services; the CLI file is never changed."
                     : "Keys stay in the macOS Keychain and are sent only to the selected provider’s quota endpoint.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { hasKey = KeychainStore.has(account: account) }
        .onChange(of: enabled) { _, value in
            status = ""
            if value { UserDefaults.standard.set(true, forKey: "display.provider.\(provider.rawValue)") }
        }
        .onChange(of: region) { _, _ in status = "" }
        .onChange(of: project) { _, _ in status = "" }
    }
}
