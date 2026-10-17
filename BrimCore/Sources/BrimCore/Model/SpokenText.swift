import Foundation

/// Joins fragments into something a screen reader can read. Pieces come
/// with and without full stops, and joining them with ". " made a reader say
/// both stops.
public enum SpokenText {

    /// One sentence per fragment, each ending in exactly one full stop. Empty
    /// fragments are dropped.
    public static func sentences(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") ? $0 : $0 + "." }
            .joined(separator: " ")
    }
}
