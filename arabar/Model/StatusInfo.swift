import Foundation

enum StatusLevel: String, Codable {
    case operational
    case degraded
    case partialOutage
    case majorOutage
    case unknown
}

struct StatusInfo: Codable, Equatable {
    let provider: Provider
    let level: StatusLevel
    let summary: String?
    let incidentURL: URL?
    let fetchedAt: Date
}
