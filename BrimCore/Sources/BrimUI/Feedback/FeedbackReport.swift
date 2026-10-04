import Foundation

public struct FeedbackReport: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: FeedbackKind
    public let title: String
    public let body: String

    public init(id: UUID = UUID(), draft: FeedbackDraft, environment: FeedbackEnvironment) {
        self.id = id
        kind = draft.kind
        title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        body = draft.markdown(environment: environment)
    }

    public var copyText: String {
        "# \(title)\n\n\(body)"
    }

    public func hasSameContent(as other: Self) -> Bool {
        kind == other.kind && title == other.title && body == other.body
    }
}
