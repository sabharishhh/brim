import Foundation
import Observation

/// What the person saw last time, so this time can say what is new.
///
/// Snapshots and subtraction, the same rule as history (`CLAUDE.md`):
/// each collection remembers the identifiers it showed when the person
/// last looked, and "new" is what is here now and was not then. No
/// watcher, no daemon. A collection that has never been looked at has no
/// snapshot, and then nothing is new, because there is nothing to compare
/// against, which is not the same as nothing having changed.
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

    /// The person has seen these. Called a moment after the rows appear,
    /// so whatever counted them as new is seen before it clears.
    public func acknowledge(_ collection: String, current: Set<String>) {
        guard seen[collection] != current else { return }
        seen[collection] = current
        file.write(Saved(seen: seen))
    }
}
