import Foundation

/// Sizes, written the way a person would say them.
///
/// `ByteCountFormatter` renders zero as "Zero KB", which reads like a fault
/// rather than a fact and turns up wherever a preferences file has no
/// content yet. Everything else it does well, so this is a thin wrapper
/// around it rather than a replacement.
///
/// Lives in `BrimCore` because a size is spoken in every layer: the model
/// writes sentences containing one and the views show them. One spelling
/// means one place, and `ByteTextConsistencyTests` fails if the raw
/// formatter reappears anywhere else.
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
