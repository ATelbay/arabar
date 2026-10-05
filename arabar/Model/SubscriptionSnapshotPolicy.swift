import Foundation

enum SubscriptionSnapshotPolicy {
    static func preferUseful(new: UsageSnapshot?, current: UsageSnapshot?, now: Date) -> UsageSnapshot? {
        guard let current else { return new }
        if SnapshotFreshnessPolicy.hasDisplayableAuthoritativeData(new, now: now) { return new }
        if SnapshotFreshnessPolicy.hasDisplayableAuthoritativeData(current, now: now) {
            guard let new else { return current }
            // Preserve the quota's original timestamp, but keep updating local usage even
            // when the remote endpoint is unavailable (including windows rolling to zero).
            return UsageSnapshot(
                provider: current.provider,
                generatedAt: current.generatedAt,
                sessionWindow: updatingUsage(current.sessionWindow, from: new.sessionWindow),
                weeklyWindow: updatingUsage(current.weeklyWindow, from: new.weeklyWindow),
                totalEventsInPeriod: new.totalEventsInPeriod
            )
        }
        if new == nil, SnapshotFreshnessPolicy.hasAuthoritativeData(current) { return current }
        return new
    }

    private static func updatingUsage(_ quota: WindowSnapshot, from local: WindowSnapshot) -> WindowSnapshot {
        WindowSnapshot(durationHours: quota.durationHours, tokensUsed: local.tokensUsed,
                       costUSD: local.costUSD, percentUsed: quota.percentUsed,
                       resetAt: quota.resetAt, percentSource: quota.percentSource)
    }
}
