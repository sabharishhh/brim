import Foundation

/// An application on this Mac, as the Applications view lists it: its
/// identity, location and bundle size. The footprint is found only by
/// `inspect(identity:)`, so the list stays fast.
public struct InstalledApplication: Codable, Equatable, Sendable, Identifiable {
    public let identity: Identity
    public let url: URL
    /// Size of the `.app` bundle alone, not of the whole footprint.
    public let bundleSizeBytes: Int64
    /// Whether macOS protects this application from removal (anything under
    /// `/System`), so the UI can say why rather than offering a dead action.
    public let isSystemProtected: Bool

    /// `LSApplicationCategoryType`, as the bundle declares it.
    public var category: String?
    /// How the app came to be here. Nil when it was never worked out.
    public var source: ApplicationSource?
    /// The organisation that signed it, in words: "Adobe Inc.", "Apple".
    public var developer: String?
    /// When Spotlight last saw it opened. Nil means Spotlight did not say,
    /// which is not the same as never opened: see `addedAt`.
    public var lastOpened: Date?
    /// When the bundle arrived where it is, as Spotlight records it.
    public var addedAt: Date?
    /// When it was installed, only when Brim can prove it: the snapshot it first
    /// appeared in. Not Spotlight's date added, which moves on every update.
    public var installedAt: Date?
    /// The application this one ships inside, such as Xcode's
    /// `Contents/Applications`. Listed, because people look for it, but never
    /// removed on its own, which would break the host's signature.
    public var enclosingApp: String?

    /// The bundle that carries this one. Removing this app means removing that
    /// one.
    public var hostURL: URL? {
        guard enclosingApp != nil else { return nil }
        return url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    public var id: String { url.path }
    public var name: String { identity.name }
    public var version: String? { identity.version }

    public init(
        identity: Identity, url: URL, bundleSizeBytes: Int64, isSystemProtected: Bool,
        category: String? = nil, source: ApplicationSource? = nil, developer: String? = nil,
        lastOpened: Date? = nil, addedAt: Date? = nil, installedAt: Date? = nil
    ) {
        self.identity = identity
        self.url = url
        self.bundleSizeBytes = bundleSizeBytes
        self.isSystemProtected = isSystemProtected
        self.category = category
        self.source = source
        self.developer = developer
        self.lastOpened = lastOpened
        self.addedAt = addedAt
        self.installedAt = installedAt
    }

    /// Whether Spotlight has a record of this bundle at all. Without one,
    /// a missing `lastOpened` says nothing about use.
    public var hasUsageRecord: Bool {
        addedAt != nil || lastOpened != nil
    }

    /// Came from another Mac and has not been opened here: the usage record
    /// predates the bundle's arrival. The gap must be a month, because macOS
    /// rewrites every bundle's date added at once on a re-index or update, and
    /// calling a used app unused costs more than the reverse.
    public var isMigratedAndUnopened: Bool {
        guard let lastOpened, let addedAt else { return false }
        return addedAt.timeIntervalSince(lastOpened) > Self.migrationGap
    }

    static let migrationGap: TimeInterval = 30 * 24 * 60 * 60
}
