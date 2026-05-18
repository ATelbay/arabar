import Foundation

enum SnapshotFreshness: Equatable {
    case fresh
    case stale
    case expired
}

enum SnapshotFreshnessPolicy {
    static let freshInterval: TimeInterval = 2 * 60
    static let expirationInterval: TimeInterval = 30 * 60

    static func age(of generatedAt: Date, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(generatedAt))
    }

    static func freshness(generatedAt: Date, now: Date) -> SnapshotFreshness {
        let age = age(of: generatedAt, now: now)
        if age <= freshInterval { return .fresh }
        if age <= expirationInterval { return .stale }
        return .expired
    }

    static func freshness(of window: WindowSnapshot, generatedAt: Date, now: Date) -> SnapshotFreshness? {
        guard window.percentSource == .authoritative else { return nil }
        if let resetAt = window.resetAt, resetAt <= now {
            return .expired
        }
        return freshness(generatedAt: generatedAt, now: now)
    }

    static func freshness(of snapshot: UsageSnapshot, now: Date) -> SnapshotFreshness? {
        let windowFreshness = [
            freshness(of: snapshot.sessionWindow, generatedAt: snapshot.generatedAt, now: now),
            freshness(of: snapshot.weeklyWindow, generatedAt: snapshot.generatedAt, now: now)
        ].compactMap { $0 }

        guard !windowFreshness.isEmpty else { return nil }
        if windowFreshness.allSatisfy({ $0 == .expired }) { return .expired }
        if windowFreshness.contains(.expired) || windowFreshness.contains(.stale) { return .stale }
        return .fresh
    }

    static func shouldSuppressPercent(for window: WindowSnapshot, generatedAt: Date, now: Date) -> Bool {
        freshness(of: window, generatedAt: generatedAt, now: now) == .expired
    }

    static func hasAuthoritativeData(_ snapshot: UsageSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.sessionWindow.percentSource == .authoritative
            || snapshot.weeklyWindow.percentSource == .authoritative
    }

    static func hasDisplayableAuthoritativeData(_ snapshot: UsageSnapshot?, now: Date) -> Bool {
        guard let snapshot else { return false }
        return [snapshot.sessionWindow, snapshot.weeklyWindow].contains { window in
            window.percentSource == .authoritative
                && window.percentUsed != nil
                && !shouldSuppressPercent(for: window, generatedAt: snapshot.generatedAt, now: now)
        }
    }

    static func isExpiredForSticky(_ snapshot: UsageSnapshot?, now: Date) -> Bool {
        guard hasAuthoritativeData(snapshot) else { return false }
        return !hasDisplayableAuthoritativeData(snapshot, now: now)
    }
}
