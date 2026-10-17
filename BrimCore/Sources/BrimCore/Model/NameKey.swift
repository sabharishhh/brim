import CoreServices
import Foundation
import Synchronization

/// The one way a file's name is compared with an application's: lower case,
/// letters and digits only. Developers spell names several ways on disk
/// (`Code`, `VSCode`, `visual-studio-code`), and every part of Brim must
/// agree on whose a folder is.
public enum NameKey {
    public static func of(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }

    /// Whether a name is an ordinary dictionary word. A word like "Reader" names
    /// many things, so a folder sharing it with an identifier is not on its own
    /// that app's; "SystemEQ" is not a word.
    public static func isOrdinaryWord(_ name: String) -> Bool {
        let word = name.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return false }
        if let known = cache.withLock({ $0[word.lowercased()] }) {
            return known
        }
        let range = CFRange(location: 0, length: (word as NSString).length)
        let found = DCSCopyTextDefinition(nil, word as CFString, range) != nil
        cache.withLock { $0[word.lowercased()] = found }
        return found
    }

    private static let cache = Mutex<[String: Bool]>([:])
}
