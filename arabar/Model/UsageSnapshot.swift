import Foundation

enum PercentSource: String, Codable {
    case authoritative  // real utilization from provider's own API (cookies path)
    case estimated      // computed from community-guessed PlanLimits.maxTokens
    case unknown        // PlanLimits.maxTokens is nil; no meaningful percent possible
}

struct WindowSnapshot: Codable, Equatable {
    let durationHours: Int          // 5 or 168
    let tokensUsed: Int             // sum of all token types in window
    let costUSD: Double             // calculated via Pricing.swift
    let percentUsed: Double?        // 0..1, nil if limit unknown
    let resetAt: Date?              // firstEventInWindow + duration, nil if window empty
    let percentSource: PercentSource
}

struct UsageSnapshot: Codable, Equatable {
    let provider: Provider
    let generatedAt: Date
    let sessionWindow: WindowSnapshot   // 5-hour
    let weeklyWindow: WindowSnapshot    // 168-hour
    let totalEventsInPeriod: Int
}
