import BrimCore
import Foundation

/// Why an installer could not be looked inside.
public enum InstallerReadError: LocalizedError, Equatable {
    case notAnInstaller
    case olderPackage
    case encrypted
    case licence
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .notAnInstaller: "This is not a package, disk image or app."
        case .olderPackage: "This older kind of package cannot be read. Open it with Installer to see its contents."
        case .encrypted: "This disk image needs a password. Open it in Finder, then drop what is inside on Brim."
        case .licence:
            "This disk image shows a licence before it opens. Open it in Finder, agree if you choose to, "
                + "then drop what is inside on Brim."
        case .unreadable: "The installer could not be read."
        }
    }
}

/// Reads an installer without installing it: a package's own file list
/// and scripts, a disk image's contents mounted read-only and hidden, and
/// an application's bundle. Nothing here writes outside a private
/// temporary folder, which is removed before it returns.
public struct InstallerReader: Sendable {
    /// An application on this Mac now, by identifier in lower case.
    public struct Installed: Sendable {
        public let version: String?
        public let path: String

        public init(version: String?, path: String) {
            self.version = version
            self.path = path
        }
    }

    let installed: [String: Installed]
    let root: FileSystemRoot
    /// An application's icon as PNG. AppKit draws it, so the service hands
    /// it in.
    let icon: @Sendable (URL) -> Data?

    public init(
        installed: [String: Installed], root: FileSystemRoot = FileSystemRoot(),
        icon: @escaping @Sendable (URL) -> Data? = { _ in nil }
    ) {
        self.installed = installed
        self.root = root
        self.icon = icon
    }

    public func read(_ url: URL) throws -> InstallerPreview {
        switch Self.kind(of: url) {
        case .application: return readApplication(url)
        case .package: return try readPackage(url)
        case .diskImage: return try readDiskImage(url)
        case nil:
            if ["pkg", "mpkg"].contains(url.pathExtension.lowercased()), Self.isFolder(url) {
                throw InstallerReadError.olderPackage
            }
            throw InstallerReadError.notAnInstaller
        }
    }

    // MARK: - Kind

    /// By content, never by name alone: a download can be called anything.
    static func kind(of url: URL) -> InstallerPreview.Kind? {
        if isFolder(url) {
            let info = url.appendingPathComponent("Contents/Info.plist")
            return url.pathExtension.lowercased() == "app" && FileManager.default.fileExists(atPath: info.path)
                ? .application : nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if let head = try? handle.read(upToCount: 4), head == Data("xar!".utf8) {
            return .package
        }
        if let end = try? handle.seekToEnd(), end >= 512 {
            try? handle.seek(toOffset: end - 512)
            if let trailer = try? handle.read(upToCount: 4), trailer == Data("koly".utf8) {
                return .diskImage
            }
        }
        return nil
    }

    static func isFolder(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// A private folder for the run, removed by the caller.
    static func workspace() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    func replaced(_ identifier: String?) -> Installed? {
        identifier.flatMap { installed[$0.lowercased()] }
    }

    // MARK: - Gatekeeper

    /// Gatekeeper's verdict for an app (`execute`), a package (`install`)
    /// or a disk image (`open`).
    static func gatekeeper(_ url: URL, type: String) -> InstallerSignature.Verdict {
        var arguments = ["--assess", "--type", type, "-vv"]
        if type == "open" {
            arguments += ["--context", "context:primary-signature"]
        }
        guard let outcome = ToolOutput.run("/usr/sbin/spctl", arguments + [url.path], timeout: 30) else {
            return .unknown(nil)
        }
        return InstallerSignature.verdict(status: outcome.status, assessment: outcome.errors + outcome.output)
    }
}
