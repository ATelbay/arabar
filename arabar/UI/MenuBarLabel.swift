import SwiftUI

enum MenuBarDisplayPolicy {
    /// Prefer the short session window when it is available. Weekly-only plans fall back to
    /// the weekly window, and an expired session window does not mask a usable weekly one.
    static func preferredWindow(in snapshot: UsageSnapshot, now: Date) -> WindowSnapshot? {
        let authoritative = [snapshot.sessionWindow, snapshot.weeklyWindow].filter {
            $0.percentSource == .authoritative && $0.percentUsed != nil
        }
        return authoritative.first {
            !SnapshotFreshnessPolicy.shouldSuppressPercent(
                for: $0,
                generatedAt: snapshot.generatedAt,
                now: now
            )
        } ?? authoritative.first
    }
}

struct MenuBarLabel: View {
    @ObservedObject var viewModel: AppViewModel
    @AppStorage("display.provider.claude") private var showClaude = true
    @AppStorage("display.provider.openai") private var showOpenAI = true
    @AppStorage("display.provider.gemini") private var showGemini = false
    @AppStorage("display.provider.kimi") private var showKimi = false
    @AppStorage("display.provider.glm") private var showGLM = false

    private var providers: [Provider] {
        Provider.allCases.filter { provider in
            switch provider {
            case .claude: return showClaude
            case .codex: return showOpenAI
            case .gemini: return showGemini
            case .kimi: return showKimi
            case .glm: return showGLM
            }
        }
    }

    @ViewBuilder
    var body: some View {
        Group {
            if let provider = currentProvider() {
                providerChip(provider: provider)
            } else {
                Text("arabar")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
    }

    private func currentProvider() -> Provider? {
        guard !providers.isEmpty else { return nil }
        let index = ((viewModel.rotationIndex % providers.count) + providers.count) % providers.count
        return providers[index]
    }

    @ViewBuilder
    private func providerChip(provider: Provider) -> some View {
        let snap = viewModel.snapshot(for: provider)
        let status = viewModel.status(for: provider)
        let now = Date()
        let window = snap.flatMap { MenuBarDisplayPolicy.preferredWindow(in: $0, now: now) }
        let isExpired = window.map { selectedWindow in
            SnapshotFreshnessPolicy.shouldSuppressPercent(
                for: selectedWindow,
                generatedAt: snap?.generatedAt ?? now,
                now: now
            )
        } ?? false
        let logoName = (provider == .claude) ? "AnthropicLogo" : "OpenAILogo"
        let isAlerting = status?.level == .partialOutage || status?.level == .majorOutage

        HStack(spacing: 3) {
            if isAlerting {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
            }
            if provider.usesAccountQuota {
                Image(systemName: provider.symbolName)
                    .font(.system(size: 11))
                Text(provider.displayName)
                if let remaining = viewModel.accountQuotas[provider]?.remainingFraction(now: now) {
                    Text("\(Int((remaining * 100).rounded()))%")
                        .foregroundColor(color(for: remaining))
                        .help("Remaining in the most constrained reported quota. Open the menu for all limits.")
                } else {
                    Text("ukwn")
                        .foregroundColor(.secondary)
                        .help(viewModel.accountQuotaErrors[provider] ?? "Connect your account in Settings → Account limits.")
                }
            } else {
                logoImage(named: logoName, size: 11)
                if !isExpired, let percentUsed = window?.percentUsed {
                    let remaining = 1.0 - percentUsed
                    Text("\(Int((remaining * 100).rounded()))%")
                        .foregroundColor(color(for: remaining))
                } else {
                    Text("ukwn")
                        .foregroundColor(.secondary)
                        .help(isExpired ? "Cached usage data expired. Refresh to update." : "Subscription limit unknown — enable browser cookies in Settings for an accurate %.")
                }
            }
        }
        .transition(.opacity)
        .id(provider)
    }

    private func color(for remaining: Double) -> Color {
        switch Int((remaining * 100).rounded()) {
        case 31...: return .primary
        case 10...30: return .orange
        default: return .red
        }
    }

    private func logoImage(named name: String, size: CGFloat) -> some View {
        let image: NSImage = {
            guard let ns = NSImage(named: name) else { return NSImage() }
            let resized = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                ns.draw(in: rect)
                return true
            }
            resized.isTemplate = true
            return resized
        }()
        return Image(nsImage: image)
    }
}
