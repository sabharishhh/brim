import Foundation

/// The icon for something that has a name and no image.
///
/// A leftover whose application is long gone, and whose icon Brim never
/// saw, still has an owner name. One or two letters on one of eight muted
/// colours is enough for the eye to tell two owners apart and to find the
/// same owner again in another list, which a grey question mark is not.
///
/// The colour is derived from the name, never stored and never random: the
/// same owner is the same colour in every list and on every launch, and
/// there is nothing to migrate.
public struct Monogram: Equatable, Sendable {
    public static let hueCount = 8

    /// One or two capital letters.
    public let letters: String
    /// Which of the eight palette hues, `0..<hueCount`.
    public let hue: Int

    public init(name: String) {
        letters = Self.letters(for: name)
        hue = Self.hue(for: name)
    }

    static func letters(for name: String) -> String {
        let words = readable(name).split { !$0.isLetter && !$0.isNumber }
        guard let firstWord = words.first, let first = firstWord.first else { return "?" }
        if words.count > 1, let second = words[1].first {
            return (String(first) + String(second)).uppercased()
        }
        // `OneDrive`, `GitHub`: a capital after a lower case letter starts
        // the second word the name already has.
        let characters = Array(firstWord)
        if let index = characters.indices.dropFirst().first(where: {
            characters[$0].isUppercase && characters[$0 - 1].isLowercase
        }) {
            return (String(first) + String(characters[index])).uppercased()
        }
        return String(first).uppercased()
    }

    /// A reverse DNS identifier reads as its last part. `com.vendor.tool`
    /// is "tool" to a person, and "CV" would name the domain registry.
    private static func readable(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" ") else { return trimmed }
        let parts = trimmed.split(separator: ".")
        return parts.count > 2 ? String(parts[parts.count - 1]) : trimmed
    }

    static func hue(for name: String) -> Int {
        var hash: UInt64 = 5381
        for byte in name.lowercased().utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Int(hash % UInt64(hueCount))
    }
}
