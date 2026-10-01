import Foundation

/// Only text the person wrote and the basic version information they opted
/// into. Feedback never reads logs, app inventory, file paths or identifiers.
public struct FeedbackDraft: Codable, Equatable, Sendable {
    public var kind: FeedbackKind = .bug
    public var title = ""
    public var details = ""
    public var reproduction = ""
    public var expected = ""
    public var includesEnvironment = false

    public init() {}

    public var isEmpty: Bool {
        [title, details, reproduction, expected].allSatisfy(\.trimmed.isEmpty)
    }

    public var validationMessage: String? {
        if title.trimmed.isEmpty {
            return "Add a short title for your report."
        }
        if title.count > 120 {
            return "Keep the title within 120 characters."
        }
        if details.trimmed.isEmpty {
            return "Add a description so we can understand your feedback."
        }
        if details.count > 6000 {
            return "Keep the description within 6,000 characters."
        }
        if kind == .bug, reproduction.count > 4000 {
            return "Keep the steps within 4,000 characters."
        }
        if kind == .bug, expected.count > 2000 {
            return "Keep the expected result within 2,000 characters."
        }
        return nil
    }

    public func markdown(environment: FeedbackEnvironment) -> String {
        var sections = ["## \(kind.title)", details.trimmed]
        if kind == .bug {
            if !reproduction.trimmed.isEmpty {
                sections += ["### Steps to reproduce", reproduction.trimmed]
            }
            if !expected.trimmed.isEmpty {
                sections += ["### Expected result", expected.trimmed]
            }
        }
        if includesEnvironment {
            sections += ["### App and system", environment.text]
        }
        return sections.joined(separator: "\n\n")
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
