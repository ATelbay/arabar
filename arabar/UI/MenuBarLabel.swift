import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var viewModel: AppViewModel

    private let providers: [Provider] = [.claude, .codex]

    var body: some View {
        providerChip(provider: currentProvider())
            .font(.system(size: 12, weight: .medium, design: .monospaced))
    }

    private func currentProvider() -> Provider {
        let idx = ((viewModel.rotationIndex % providers.count) + providers.count) % providers.count
        return providers[idx]
    }

    @ViewBuilder
    private func providerChip(provider: Provider) -> some View {
        let snap = (provider == .claude) ? viewModel.claudeSnapshot : viewModel.codexSnapshot
        let status = (provider == .claude) ? viewModel.claudeStatus : viewModel.codexStatus
        let window = snap?.sessionWindow
        let source = window?.percentSource ?? .unknown
        let pct = window?.percentUsed ?? 0
        let isExpired = window.map { win in
            SnapshotFreshnessPolicy.shouldSuppressPercent(
                for: win,
                generatedAt: snap?.generatedAt ?? Date(),
                now: Date()
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
            logoImage(named: logoName, size: 11)
            if !isExpired, source == .authoritative, let _ = window?.percentUsed {
                let remaining = 1.0 - pct
                Text("\(Int((remaining * 100).rounded()))%")
                    .foregroundColor(color(for: remaining))
            } else {
                Text("ukwn")
                    .foregroundColor(.secondary)
                    .help(isExpired ? "Cached usage data expired. Refresh to update." : "Subscription limit unknown — enable browser cookies in Settings for an accurate %.")
            }
        }
        .transition(.opacity)
        .id(provider)
    }

    private func color(for remaining: Double) -> Color {
        switch remaining {
        case let r where r > 0.30: return .primary
        case 0.10..<0.30: return .orange
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
