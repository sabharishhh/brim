import Foundation

public struct BTMRecord: Equatable, Sendable {
    public let uuid: String
    public let namespace: String?
    public let storePath: String?
    public let rawType: Int?
    public let rawDisposition: Int?
    public let name: String?
    public let developerName: String?
    public let type: String?
    public let disposition: String?
    public let identifier: String?
    /// The URL exactly as recorded, which may be relative: an embedded item's
    /// path is relative to its parent bundle
    /// (`Contents/Library/LoginItems/Helper.app`).
    public let rawURLPath: String?
    /// The identifier of the item this one is embedded in: the anchor for a
    /// relative URL, and what attributes a helper to the app that ships it.
    public let parentIdentifier: String?
    public let bundleIdentifier: String?
    /// The signing team macOS recorded when it accepted this item.
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
        teamIdentifier: String? = nil,
        namespace: String? = nil, storePath: String? = nil,
        rawType: Int? = nil, rawDisposition: Int? = nil
    ) {
        self.uuid = uuid
        self.namespace = namespace
        self.storePath = storePath
        self.rawType = rawType
        self.rawDisposition = rawDisposition
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

    func inStore(_ path: String, namespace: String) -> Self {
        Self(uuid: uuid, name: name, developerName: developerName, type: type,
             disposition: disposition, identifier: identifier, rawURLPath: rawURLPath,
             parentIdentifier: parentIdentifier, bundleIdentifier: bundleIdentifier,
             teamIdentifier: teamIdentifier, namespace: namespace, storePath: path,
             rawType: rawType, rawDisposition: rawDisposition)
    }
}
