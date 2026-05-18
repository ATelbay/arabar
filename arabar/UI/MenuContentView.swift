import SwiftUI

struct MenuContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @StateObject private var loginItem = LoginItemController()
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
                if let warning = freshnessWarning(for: snapshot) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(warning.isCritical ? .red : .orange)
                            .font(.caption2)
                        Text(warning.text)
                            .font(.caption2)
                            .foregroundColor(warning.isCritical ? .red : .orange)
                    }
                }

                windowRow(label: "5h", window: snapshot.sessionWindow, generatedAt: snapshot.generatedAt)
                windowRow(label: "7d", window: snapshot.weeklyWindow, generatedAt: snapshot.generatedAt)

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

    // MARK: - Snapshot freshness warning helpers

    private func freshnessWarning(for snapshot: UsageSnapshot) -> (text: String, isCritical: Bool)? {
        let now = Date()
        guard let freshness = SnapshotFreshnessPolicy.freshness(of: snapshot, now: now), freshness != .fresh else {
            return nil
        }
        let prefix = freshness == .expired ? "Expired" : "Stale"
        return ("\(prefix) · updated \(shortAge(since: snapshot.generatedAt, now: now))", freshness == .expired)
    }

    private func shortAge(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }

    // MARK: - Window row (progress bar + labels)

    @ViewBuilder
    private func windowRow(label: String, window: WindowSnapshot, generatedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 20, alignment: .leading)

                ProgressView(value: barFillValue(for: window, generatedAt: generatedAt))
                    .tint(progressBarColor(for: window, generatedAt: generatedAt))
                    .frame(maxWidth: .infinity)

                percentLabel(for: window, generatedAt: generatedAt)
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
    private func percentLabel(for window: WindowSnapshot, generatedAt: Date) -> some View {
        let now = Date()
        if SnapshotFreshnessPolicy.shouldSuppressPercent(for: window, generatedAt: generatedAt, now: now) {
            Text("ukwn")
                .font(.caption)
                .foregroundColor(.secondary)
                .help("Cached usage data expired. Refresh to update.")
        } else if window.percentSource == .authoritative, let pct = window.percentUsed {
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
                        .help("Last successful usage refresh. Failed refresh attempts do not update this time.")
                } else {
                    Text("Not yet refreshed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .help("No usage refresh has completed successfully yet.")
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

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)

                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private func remainingColor(for remaining: Double) -> Color {
        switch Int((remaining * 100).rounded()) {
        case 31...: return .accentColor
        case 10...30: return .orange
        default: return .red
        }
    }

    private func progressBarColor(for window: WindowSnapshot, generatedAt: Date) -> Color {
        if !SnapshotFreshnessPolicy.shouldSuppressPercent(for: window, generatedAt: generatedAt, now: Date()),
           window.percentSource == .authoritative,
           let used = window.percentUsed {
            return remainingColor(for: 1.0 - used)
        }
        return Color.secondary.opacity(0.3)
    }

    // Bar fill represents remaining (shrinks as usage grows), matching the "X% left" framing.
    private func barFillValue(for window: WindowSnapshot, generatedAt: Date) -> Double {
        guard !SnapshotFreshnessPolicy.shouldSuppressPercent(for: window, generatedAt: generatedAt, now: Date()),
              let used = window.percentUsed else { return 0 }
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
