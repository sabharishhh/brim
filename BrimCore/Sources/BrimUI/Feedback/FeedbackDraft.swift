import Foundation

/// Text the person wrote and basic app and system versions. Feedback never
/// reads logs, app inventory, file paths or identifiers.
public struct FeedbackDraft: Codable, Equatable, Sendable {
    public var kind: FeedbackKind = .bug
    public var title = ""
    public var details = ""
    public var reproduction = ""
    public var expected = ""

    public init() {}

    public var isEmpty: Bool {
        [title, details, reproduction, expected].allSatisfy(\.trimmed.isEmpty)
    }

    /// How long each field may be. GitHub accepts 256 characters in a
    /// title, but its lists cut a title off well before that, so a report is
    /// read by a title that fits one line. The body has room for far more
    /// than these; they keep a report something a person will read.
    public enum Limit {
        public static let title = 100
        public static let details = 5000
        public static let reproduction = 3000
        public static let expected = 1000
    }

    public var validationMessage: String? {
        if title.trimmed.isEmpty {
            return "Add a short title for your report."
        }
        if title.count > Limit.title {
            return "Keep the title within \(Limit.title) characters."
        }
        if details.trimmed.isEmpty {
            return "Add a description."
        }
        if details.count > Limit.details {
            return "Keep the description within 5,000 characters."
        }
        if kind == .bug, reproduction.count > Limit.reproduction {
            return "Keep the steps within 3,000 characters."
        }
        if kind == .bug, expected.count > Limit.expected {
            return "Keep the expected result within 1,000 characters."
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
        sections += ["### App and system", environment.text]
        return sections.joined(separator: "\n\n")
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
