import SwiftUI
import AppKit

struct MenuContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @StateObject private var loginItem = LoginItemController()
    @StateObject private var optionKey = OptionKeyMonitor()
    @Environment(\.openWindow) private var openWindow

    private let relativeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──────────────────────────────────────────────────
            Text("arabar")
                .font(.headline)
                .padding(.bottom, 8)

            // ── Claude primary section ───────────────────────────────────
            providerSection(
                icon: "brain",
                title: "Claude Code",
                snapshot: viewModel.claudeSnapshot,
                status: viewModel.claudeStatus,
                provider: .claude
            )

            // ── Claude API secondary section (only when distinct) ────────
            if let apiSnap = viewModel.claudeApiSnapshot, apiSnap != viewModel.claudeSnapshot {
                Divider().padding(.vertical, 4)
                if viewModel.claudeSnapshot != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption2)
                        Text("Subscription + API may count same tokens twice")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                providerSection(
                    icon: "bolt.circle",
                    title: "Claude API",
                    snapshot: apiSnap,
                    status: nil,
                    provider: nil
                )
            }

            Divider().padding(.vertical, 8)

            // ── Codex / ChatGPT primary section ─────────────────────────
            providerSection(
                icon: "message.fill",
                title: "ChatGPT / Codex",
                snapshot: viewModel.codexSnapshot,
                status: viewModel.codexStatus,
                provider: .codex
            )

            // ── OpenAI API secondary section (only when distinct) ────────
            if let apiSnap = viewModel.codexApiSnapshot, apiSnap != viewModel.codexSnapshot {
                Divider().padding(.vertical, 4)
                if viewModel.codexSnapshot != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption2)
                        Text("Subscription + API may count same tokens twice")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                providerSection(
                    icon: "bolt.circle",
                    title: "OpenAI API",
                    snapshot: apiSnap,
                    status: nil,
                    provider: nil
                )
            }

            Divider().padding(.vertical, 8)

            // ── Footer ──────────────────────────────────────────────────
            footer
        }
        .padding(12)
        .frame(width: 280)
        .task {
            if viewModel.lastRefreshAt == nil {
                await viewModel.refresh()
            }
        }
    }

    // MARK: - Provider section

    @ViewBuilder
    private func providerSection(
        icon: String,
        title: String,
        snapshot: UsageSnapshot?,
        status: StatusInfo?,
        provider: Provider?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title row
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            // Cookie TTL warning
            if let p = provider,
               let expiry = expiryDate(for: p),
               let warning = expiryWarning(from: expiry) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(warning.isCritical ? .red : .orange)
                        .font(.caption2)
                    Text(warning.text)
                        .font(.caption2)
                        .foregroundColor(warning.isCritical ? .red : .orange)
                }
            }

            if let snapshot = snapshot {
                windowRow(label: "5h", window: snapshot.sessionWindow)
                windowRow(label: "7d", window: snapshot.weeklyWindow)

                if let level = status?.level,
                   level != .operational,
                   level != .unknown,
                   let summary = status?.summary {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(summary)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .lineLimit(2)
                    }
                }
            } else {
                Text("Loading…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Cookie expiry warning helpers

    private func expiryDate(for provider: Provider) -> Date? {
        switch provider {
        case .claude: return viewModel.claudeCookieExpiresAt
        case .codex:  return viewModel.codexCookieExpiresAt
        }
    }

    private func expiryWarning(from expiry: Date) -> (text: String, isCritical: Bool)? {
        let delta = expiry.timeIntervalSinceNow
        guard delta >= 0 else { return nil }
        let hours = delta / 3600
        if hours < 1 {
            let minutes = Int(delta / 60)
            return ("Session expires in \(minutes)m", true)
        } else if hours < 24 {
            return ("Session expires in \(Int(hours))h", true)
        } else if hours < 72 {
            let days = Int(hours / 24)
            return ("Session expires in \(days) day\(days == 1 ? "" : "s")", false)
        }
        return nil
    }

    // MARK: - Window row (progress bar + labels)

    @ViewBuilder
    private func windowRow(label: String, window: WindowSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 20, alignment: .leading)

                ProgressView(value: barFillValue(for: window))
                    .tint(progressBarColor(for: window))
                    .frame(maxWidth: .infinity)

                percentLabel(for: window)
                    .frame(width: 34, alignment: .trailing)
            }

            HStack {
                Spacer().frame(width: 24)
                Text("\(formatTokens(window.tokensUsed)) tokens · \(formatCost(window.costUSD))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if let resetAt = window.resetAt {
                    Text(resetIn(resetAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func percentLabel(for window: WindowSnapshot) -> some View {
        if window.percentSource == .authoritative, let pct = window.percentUsed {
            let remaining = 1.0 - pct
            Text("\(Int((remaining * 100).rounded()))%")
                .font(.caption)
                .foregroundColor(remainingColor(for: remaining))
        } else {
            Text("ukwn")
                .font(.caption)
                .foregroundColor(.secondary)
                .help("Subscription limit unknown — enable browser cookies in Settings for an accurate %.")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: toggle + last refresh time
            HStack {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { _ in loginItem.toggle() }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)

                Spacer()

                if let last = viewModel.lastRefreshAt {
                    Text("Updated \(relativeFmt.localizedString(for: last, relativeTo: Date()))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("Not yet refreshed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Row 2: action buttons (left-clustered)
            HStack {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .disabled(viewModel.isRefreshing)
                .help("Refresh now")

                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",")

                if optionKey.isHeld {
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q", modifiers: .command)
                } else {
                    Text("⌥ to quit")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .help("Hold the Option key to reveal the Quit button.")
                }

                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private func remainingColor(for remaining: Double) -> Color {
        switch remaining {
        case let r where r > 0.30: return .accentColor
        case 0.10..<0.30: return .orange
        default: return .red
        }
    }

    private func progressBarColor(for window: WindowSnapshot) -> Color {
        if window.percentSource == .authoritative, let used = window.percentUsed {
            return remainingColor(for: 1.0 - used)
        }
        return Color.secondary.opacity(0.3)
    }

    // Bar fill represents remaining (shrinks as usage grows), matching the "X% left" framing.
    private func barFillValue(for window: WindowSnapshot) -> Double {
        guard let used = window.percentUsed else { return 0 }
        return max(0, min(1.0 - used, 1.0))
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return String(format: "%.1fM", m)
        } else if n >= 1_000 {
            let k = Double(n) / 1_000
            return String(format: "%.1fk", k)
        }
        return "\(n)"
    }

    private func formatCost(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    private func resetIn(_ date: Date) -> String {
        let now = Date()
        guard date > now else { return "reset" }
        let comps = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: date)
        let days = comps.day ?? 0
        let hours = comps.hour ?? 0
        let minutes = comps.minute ?? 0
        if days >= 1 {
            return "in \(days)d \(hours)h"
        } else if hours >= 1 {
            return "in \(hours)h \(minutes)m"
        } else {
            return "in \(max(minutes, 0))m"
        }
    }
}

// Tracks whether the Option (⌥) modifier is currently held. Used to gate the Quit
// button — accessibility-emulated or stray mouseUp events have been observed
// targeting the menubar popover and triggering NSApp.terminate; requiring Option
// blocks any single phantom click from quitting the app.
@MainActor
final class OptionKeyMonitor: ObservableObject {
    @Published var isHeld: Bool = NSEvent.modifierFlags.contains(.option)
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            let held = event.modifierFlags.contains(.option)
            Task { @MainActor in self?.isHeld = held }
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
