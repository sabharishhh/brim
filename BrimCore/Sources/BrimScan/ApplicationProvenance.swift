import Foundation

/// When an application arrived on this Mac, and when anybody last opened it.
///
/// Both come from Spotlight's metadata rather than from the filesystem,
/// and the distinction matters. A bundle's creation date is whatever the
/// vendor's archive said; `kMDItemDateAdded` is when it landed *here*.
/// Compare that against `kMDItemLastUsedDate` and a whole class of
/// software falls out: applications that came across from another Mac and
/// have not been opened since.
///
/// Observed while building this: IINA arrived on 14 September and was
/// last opened on 7 August. The usage record travelled with the bundle.
public struct ApplicationProvenance: Sendable {

    public struct Dates: Equatable, Sendable {
        public let addedAt: Date?
        public let lastUsedAt: Date?

        public init(addedAt: Date?, lastUsedAt: Date?) {
            self.addedAt = addedAt
            self.lastUsedAt = lastUsedAt
        }
    }

    public init() {}

    /// What Spotlight knows about one bundle.
    ///
    /// Absent answers are normal and are not failures: Spotlight can be
    /// switched off for a volume, and a freshly copied bundle may not be
    /// indexed yet. `MigrationHygiene` treats a missing date as "not
    /// enough to say" rather than as evidence of anything.
    public func dates(for bundleURL: URL) -> Dates {
        guard let item = NSMetadataItem(url: bundleURL) else {
            return Dates(addedAt: nil, lastUsedAt: nil)
        }
        return Dates(
            addedAt: item.value(forAttribute: "kMDItemDateAdded") as? Date,
            lastUsedAt: item.value(forAttribute: "kMDItemLastUsedDate") as? Date
        )
    }

    /// When this installation of macOS was set up.
    ///
    /// `/var/db/.AppleSetupDone` is written once, when the setup
    /// assistant finishes, and never touched again. An application older
    /// than that came from somewhere else.
    public func systemInstalledAt(
        markerPath: String = "/var/db/.AppleSetupDone"
    ) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: markerPath)
        else { return nil }
        return attributes[.creationDate] as? Date
    }
}
