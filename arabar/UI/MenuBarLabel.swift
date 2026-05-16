import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var currentIndex: Int = 0

    private let providers: [Provider] = [.claude, .codex]
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        providerChip(provider: currentProvider())
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .onReceive(timer) { _ in
                advance()
            }
    }

    private func currentProvider() -> Provider {
        providers[currentIndex % providers.count]
    }

    private func advance() {
        currentIndex = (currentIndex + 1) % providers.count
    }

    @ViewBuilder
    private func providerChip(provider: Provider) -> some View {
        let snap = (provider == .claude) ? viewModel.claudeSnapshot : viewModel.codexSnapshot
        let status = (provider == .claude) ? viewModel.claudeStatus : viewModel.codexStatus
        let window = snap?.sessionWindow
        let source = window?.percentSource ?? .unknown
        let pct = window?.percentUsed ?? 0
        let logoName = (provider == .claude) ? "AnthropicLogo" : "OpenAILogo"
        let isAlerting = status != nil && status?.level != .operational && status?.level != .unknown

        HStack(spacing: 3) {
            if isAlerting {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
            }
            logoImage(named: logoName, size: 11)
            if source == .authoritative, let _ = window?.percentUsed {
                let remaining = 1.0 - pct
                Text("\(Int((remaining * 100).rounded()))%")
                    .foregroundColor(color(for: remaining))
            } else {
                Text("ukwn")
                    .foregroundColor(.secondary)
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
