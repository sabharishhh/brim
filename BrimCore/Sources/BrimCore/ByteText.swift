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

    /// For a size shown on its own, in a column or beside a name. Zero is
    /// "0 KB", a number among numbers. It was "Empty", which said nothing was
    /// there: a removed app whose folders took no space read "Empty" beside
    /// a Finish Removal button, and Home showed "Empty" over "From 1 removed
    /// app".
    public static func short(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
