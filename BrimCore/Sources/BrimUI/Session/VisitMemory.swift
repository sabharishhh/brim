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
        var lastVisit: Date?
        var seen: [String: Set<String>] = [:]
    }

    /// When the person last opened Brim before this launch. Home's
    /// "Since your last visit" is measured from here.
    public private(set) var lastVisit: Date?
    private var seen: [String: Set<String>]
    private let file: JSONFile<Saved>

    public init(file: URL?) {
        self.file = JSONFile(url: file)
        let saved = self.file.read() ?? Saved()
        lastVisit = saved.lastVisit
        seen = saved.seen
    }

    /// Records this launch as a visit. `lastVisit` keeps the previous one
    /// for the rest of the session, which is the one people mean.
    public func begin(now: Date = .now) {
        file.write(Saved(lastVisit: now, seen: seen))
    }

    public func hasSnapshot(of collection: String) -> Bool {
        seen[collection] != nil
    }

    /// The identifiers that were not there the last time this collection
    /// was looked at. Empty when it never was.
    public func newItems(in collection: String, current: Set<String>) -> Set<String> {
        guard let before = seen[collection] else { return [] }
        return current.subtracting(before)
    }

    /// The person has seen these. Called a moment after the rows appear,
    /// so the dots are seen before they go.
    public func acknowledge(_ collection: String, current: Set<String>) {
        guard seen[collection] != current else { return }
        seen[collection] = current
        var saved = file.read() ?? Saved()
        saved.seen = seen
        file.write(saved)
    }
}
