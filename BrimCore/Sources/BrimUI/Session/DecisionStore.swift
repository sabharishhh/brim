import Foundation
import Observation

/// What the person has said to keep.
///
/// A leftover somebody chose to keep has to stay kept, or the list asks
/// them the same question on every visit until they stop reading it.
/// Keyed by a fingerprint the collection chooses, which for a file is its
/// path: moving it somewhere else makes it a different thing to decide on.
@MainActor
@Observable
public final class DecisionStore {
    public private(set) var kept: [String: Date]
    private let file: JSONFile<[String: Date]>

    /// - Parameter file: where to save, or nil to keep decisions in memory.
    public init(file: URL?) {
        self.file = JSONFile(url: file)
        kept = self.file.read() ?? [:]
    }

    public func isKept(_ fingerprint: String) -> Bool {
        kept[fingerprint] != nil
    }

    public func keep(_ fingerprints: some Sequence<String>, now: Date = .now) {
        for fingerprint in fingerprints where kept[fingerprint] == nil {
            kept[fingerprint] = now
        }
        file.write(kept)
    }

    /// Forgets every decision, when the person asks in Settings.
    public func forgetAll() {
        kept = [:]
        file.write(kept)
    }

    public func unkeep(_ fingerprints: some Sequence<String>) {
        for fingerprint in fingerprints {
            kept[fingerprint] = nil
        }
        file.write(kept)
    }
}
