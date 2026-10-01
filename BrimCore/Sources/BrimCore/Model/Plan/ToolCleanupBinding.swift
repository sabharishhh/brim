import Foundation

/// A catalogue operation and the developer row it was requested for.
public struct ToolCleanupRequest: Codable, Equatable, Sendable {
    public enum CleanupID: String, Codable, Sendable {
        case npm = "npm.cache", goModules = "go.modcache", pip = "pip.cache"
        case homebrew = "homebrew.cleanup", pnpm = "pnpm.store", uvCache = "uv.cache"
        case simulators = "xcode.simulators", swiftPM = "swiftpm.cache"
    }

    public let id: CleanupID
    public let cachePath: URL

    public init(id: CleanupID, cachePath: URL) {
        self.id = id
        self.cachePath = cachePath
    }
}

/// Facts reconstructed from the catalogue and the tool, covered by approval.
/// The stored arguments are evidence. Execution rebuilds them independently.
public struct ToolCleanupBinding: Codable, Equatable, Sendable {
    public let id: ToolCleanupRequest.CleanupID
    public let catalogueRevision: String
    public let executable: String
    public let executableFingerprint: TargetFingerprint
    public let executableHash: String
    public let scope: String
    public let scopeDevice: Int32
    public let scopeInode: UInt64
    public let arguments: [String]
    public let environmentHash: String
    public let workingDirectory: String
    public let displayed: String

    public init(
        id: ToolCleanupRequest.CleanupID,
        catalogueRevision: String,
        executable: String,
        executableFingerprint: TargetFingerprint,
        executableHash: String,
        scope: String,
        scopeDevice: Int32,
        scopeInode: UInt64,
        arguments: [String],
        environmentHash: String,
        workingDirectory: String,
        displayed: String
    ) {
        self.id = id
        self.catalogueRevision = catalogueRevision
        self.executable = executable
        self.executableFingerprint = executableFingerprint
        self.executableHash = executableHash
        self.scope = scope
        self.scopeDevice = scopeDevice
        self.scopeInode = scopeInode
        self.arguments = arguments
        self.environmentHash = environmentHash
        self.workingDirectory = workingDirectory
        self.displayed = displayed
    }
}
