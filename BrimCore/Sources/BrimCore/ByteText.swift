import Foundation

/// Sizes as a person would say them. A thin wrapper over
/// `ByteCountFormatter`, which writes zero as "Zero KB".
/// `ByteTextConsistencyTests` fails if the raw formatter is used elsewhere.
public enum ByteText {

    /// For a size shown on its own, in a column or beside a name. Zero is
    /// "0 KB", a number among numbers, not "Empty".
    public static func short(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
