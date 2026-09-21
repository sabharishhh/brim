import Foundation

public struct BTMRecord: Equatable, Sendable {
    public let uuid: String
    public let name: String?
    public let developerName: String?
    public let type: String?
    public let disposition: String?
    public let identifier: String?
    /// The URL exactly as the dump printed it, which may be **relative**.
    ///
    /// `sfltool` prints an absolute path for a top-level item but a path
    /// relative to the parent bundle for an embedded one, for example
    /// `Contents/Library/LoginItems/Helper.app`. Resolving that as if it were
    /// absolute produces a path under the current working directory that does
    /// not exist, which reads as a stale entry when nothing is wrong.
    public let rawURLPath: String?
    /// The identifier of the item this one is embedded in, when it is a
    /// child. Both the anchor for a relative URL and the link that attributes
    /// a helper to the app that ships it.
    public let parentIdentifier: String?
    public let bundleIdentifier: String?
    /// The signing team macOS recorded when it accepted this item. The
    /// store has carried this all along and nothing read it, which is the
    /// signing state T-3.8 asks for and never got.
    public let teamIdentifier: String?

    /// The URL only when the dump gave an absolute path. A relative one needs
    /// its parent to resolve and is left to the caller.
    public var url: URL? {
        guard let rawURLPath, rawURLPath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: rawURLPath)
    }

    /// True when this record's path needs a parent to be meaningful.
    public var hasRelativeURL: Bool {
        guard let rawURLPath else { return false }
        return !rawURLPath.hasPrefix("/")
    }

    public init(
        uuid: String,
        name: String?,
        developerName: String?,
        type: String?,
        disposition: String?,
        identifier: String?,
        rawURLPath: String?,
        parentIdentifier: String? = nil,
        bundleIdentifier: String?,
        teamIdentifier: String? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.developerName = developerName
        self.type = type
        self.disposition = disposition
        self.identifier = identifier
        self.rawURLPath = rawURLPath
        self.parentIdentifier = parentIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }
}
