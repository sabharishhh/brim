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

    public var id: String { url.path }
    public var name: String { identity.name }
    public var version: String? { identity.version }

    public init(identity: Identity, url: URL, bundleSizeBytes: Int64, isSystemProtected: Bool) {
        self.identity = identity
        self.url = url
        self.bundleSizeBytes = bundleSizeBytes
        self.isSystemProtected = isSystemProtected
    }
}
