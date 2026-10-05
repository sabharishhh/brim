import CoreServices
import Foundation
import Synchronization

/// The one way a file's name is compared with an application's.
///
/// Developers spell the same name several ways on disk. ChatGPT keeps
/// `Caches/Codex` while its identifier says `codex`, Visual Studio Code is
/// `Code`, `VSCode` and `vscode`, and an Electron app can write
/// `visual-studio-code` beside `Visual Studio Code`. Every rule compared
/// exact strings, so whether a folder was found depended on how its
/// developer happened to type the name, and the Leftovers sweep, which
/// compared in lower case, disagreed with the removal, which did not.
/// Lower case with only letters and digits left is what all of those share.
public enum NameKey {
    public static func of(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }

    /// Whether a name is an ordinary word in the system dictionary. A word
    /// like "Reader" or "Codex" names many things, so a folder sharing it
    /// with an application's identifier is not, on its own, that
    /// application's. "SystemEQ" is not a word, and a folder called that
    /// beside SystemEQ for Mac is.
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
