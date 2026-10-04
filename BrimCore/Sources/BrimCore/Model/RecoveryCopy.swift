import Foundation

/// A file Brim's helper retained during an earlier removal.
public struct RecoveryCopy: Codable, Sendable, Equatable {
    public static let directory = "/Library/Application Support/Brim/Set aside"
    public let path: String
    public let name: String
    public let bundleID: String?
    public let sizeBytes: Int64
    public let sizeIsKnown: Bool
    public let fingerprint: TargetFingerprint

    public init(
        path: String, name: String, bundleID: String?, sizeBytes: Int64,
        sizeIsKnown: Bool, fingerprint: TargetFingerprint
    ) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.sizeBytes = sizeBytes
        self.sizeIsKnown = sizeIsKnown
        self.fingerprint = fingerprint
    }

    public static func identifier(for path: String) -> String? {
        guard path.hasPrefix(directory + "/") else { return nil }
        let relative = String(path.dropFirst(directory.count + 1))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\0") }),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { return nil }
        return relative
    }

    public var leftover: Leftover {
        Leftover(url: URL(fileURLWithPath: path), size: sizeBytes, category: .orphaned,
                 potentialOwner: Identity(bundleID: bundleID, name: name),
                 evidence: "Brim retained this copy during an earlier removal. "
                     + "Deleting it permanently removes the recovery copy.",
                 capability: .needsHelper, sizeIsKnown: sizeIsKnown)
    }
}
