import Foundation
import Observation

/// What the person saw last time, so this time can say what is new. Each
/// collection remembers the identifiers it showed, and "new" is what is here
/// now and was not then. A collection never looked at has nothing to
/// compare, so nothing is new.
@MainActor
@Observable
public final class VisitMemory {
    struct Saved: Codable {
        var seen: [String: Set<String>] = [:]
    }

    private var seen: [String: Set<String>]
    private let file: JSONFile<Saved>

    public init(file: URL?) {
        self.file = JSONFile(url: file)
        seen = (self.file.read() ?? Saved()).seen
    }

    /// The identifiers that were not there the last time this collection
    /// was looked at. Empty when it never was.
    public func newItems(in collection: String, current: Set<String>) -> Set<String> {
        guard let before = seen[collection] else { return [] }
        return current.subtracting(before)
    }

    /// The person has seen these. Called a moment after the rows appear, so the
    /// new marks are seen before they clear.
    public func acknowledge(_ collection: String, current: Set<String>) {
        guard seen[collection] != current else { return }
        seen[collection] = current
        file.write(Saved(seen: seen))
    }
}
