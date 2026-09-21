import Foundation

/// Sizes, written the way a person would say them.
///
/// `ByteCountFormatter` renders zero as "Zero KB", which reads like a fault
/// rather than a fact and turns up wherever a preferences file has no
/// content yet. Everything else it does well, so this is a thin wrapper
/// around it rather than a replacement.
public enum ByteText {

    /// For a size shown on its own, in a column or beside a name.
    public static func short(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "Empty" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// For a size inside a sentence, where "Empty" would not fit the
    /// grammar and "nothing" reads properly.
    public static func inSentence(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "nothing" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
