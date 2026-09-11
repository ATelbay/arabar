import Foundation

struct AccountQuotaWindow: Equatable, Identifiable {
    let id: String
    let label: String
    let remainingFraction: Double
    let resetAt: Date?

    func freshness(generatedAt: Date, now: Date) -> SnapshotFreshness {
        if let resetAt, resetAt <= now { return .expired }
        return SnapshotFreshnessPolicy.freshness(generatedAt: generatedAt, now: now)
    }
}

struct AccountQuotaSnapshot: Equatable {
    let provider: Provider
    let generatedAt: Date
    let windows: [AccountQuotaWindow]

    /// The tightest reported quota drives the menu bar; all quotas remain visible in the menu.
    /// An expired bucket cannot prove that the account still has capacity.
    func remainingFraction(now: Date) -> Double? {
        guard !windows.isEmpty,
              windows.allSatisfy({ $0.freshness(generatedAt: generatedAt, now: now) != .expired }) else {
            return nil
        }
        return windows.map(\.remainingFraction).min()
    }
}

struct AccountQuotaConfiguration: Equatable {
    let provider: Provider
    let enabled: Bool
    let region: String
    let project: String
    let revision: Int

    static func load(provider: Provider, defaults: UserDefaults = .standard) -> Self {
        let prefix = "quota.\(provider.rawValue)"
        return Self(provider: provider, enabled: defaults.bool(forKey: "\(prefix).enabled"),
                    region: defaults.string(forKey: "\(prefix).region") ?? "global",
                    project: defaults.string(forKey: "\(prefix).project") ?? "",
                    revision: defaults.integer(forKey: "\(prefix).revision"))
    }

    var keychainAccount: String { "quota.key.\(provider.rawValue)" }
}
