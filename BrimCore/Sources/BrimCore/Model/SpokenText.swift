import Foundation

/// Joining fragments into something a screen reader can read aloud.
///
/// A row's description is assembled from pieces that come from different
/// places: a label with no punctuation, a category with none, and an
/// evidence sentence that ends in a full stop because it is a sentence.
/// Joining those with ". " gives "in the user domain.. Nothing signs
/// this", and a reader says both stops.
public enum SpokenText {

    /// One sentence per fragment, each ending in exactly one full stop.
    /// Empty fragments are dropped rather than becoming a pause about
    /// nothing.
    public static func sentences(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") ? $0 : $0 + "." }
            .joined(separator: " ")
    }
}
