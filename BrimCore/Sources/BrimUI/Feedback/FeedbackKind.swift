import Foundation

public enum FeedbackKind: String, CaseIterable, Codable, Sendable {
    case bug
    case feature
    case general

    public var title: String {
        switch self {
        case .bug: "Bug report"
        case .feature: "Feature request"
        case .general: "Other feedback"
        }
    }
}
