import Foundation

/// An application present on this machine, as the Applications view lists it.
///
/// Deliberately thin: the bundle's own identity and location, plus the size of
/// the bundle itself. The *footprint* — everything the app has scattered
/// elsewhere — is not computed here. Discovering that is expensive and is what
/// `inspect(identity:)` is for, so the list stays fast and the depth is paid
/// for only when the user asks about one app.
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
    /// When it was installed, and only when Brim can prove it: the
    /// snapshot it first appeared in. Nil for anything that was already
    /// here the first time Brim looked.
    ///
    /// Not `addedAt`. Spotlight's date added moves whenever an updater
    /// replaces the bundle, and on this Mac it called Figma, Visual Studio
    /// Code, Teams and eleven more "recently installed" when every one of
    /// them had only been updated.
    public var installedAt: Date?
    /// The application this one ships inside, when it is nested: Icon
    /// Composer, Instruments and FileMerge live in Xcode's
    /// `Contents/Applications`. Such an app is listed, because people look
    /// for it, and never removed on its own, because that would break the
    /// signature of the app that carries it.
    public var enclosingApp: String?

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

    /// Came across from another Mac and has not been opened here: the
    /// usage record travelled with the bundle, so it predates the bundle's
    /// arrival (`CLAUDE.md`, on the migration signature).
    public var isMigratedAndUnopened: Bool {
        guard let lastOpened, let addedAt else { return false }
        return lastOpened < addedAt
    }
}
