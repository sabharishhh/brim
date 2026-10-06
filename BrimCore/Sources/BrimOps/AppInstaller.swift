import BrimCore
import Foundation

/// Puts an application the person has looked inside into Applications.
///
/// Only an app, loose or in a disk image: a package's scripts are its
/// developer's to run, so packages open in Apple's Installer instead and
/// Brim records around it. What is copied is checked again against what the
/// preview showed, because the file could have changed in between: the same
/// identifier, and Gatekeeper's approval when the preview said it had it.
/// `ditto` keeps the download's quarantine, so macOS still checks the app
/// the first time it opens, as it would after a drag in Finder.
public enum AppInstaller {
    public enum Failure: Error, Equatable, LocalizedError {
        case licence
        case unreadable
        case noApplication
        case differentApplication
        case gatekeeper
        case exists(String)
        case notAllowed
        case copy

        public var errorDescription: String? {
            switch self {
            case .licence:
                "This disk image shows a licence first. Open it in Finder to install from it."
            case .unreadable: "The installer could not be opened."
            case .noApplication: "There is no app in it to install."
            case .differentApplication: "The app in it changed since Brim looked inside."
            case .gatekeeper: "macOS no longer trusts this app, so Brim did not install it."
            case let .exists(name): "Applications already has an app called \(name)."
            case .notAllowed: "macOS did not let Brim add to Applications."
            case .copy: "The app could not be copied into Applications."
            }
        }
    }

    /// Installs and returns where the app now is.
    /// - Parameters:
    ///   - identifier: the bundle identifier the preview showed.
    ///   - trusted: the preview showed Gatekeeper accepting it, so it must
    ///     still be accepted.
    public static func install(
        from source: URL, identifier: String?, trusted: Bool,
        applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) throws -> URL {
        if source.pathExtension.lowercased() == "app" {
            return try place(source, identifier: identifier, trusted: trusted, into: applications)
        }
        guard UpdateInstaller.kind(of: source) == .diskImage else { throw Failure.unreadable }
        guard let info = UpdateInstaller.runOutput("/usr/bin/hdiutil", ["imageinfo", "-plist", source.path]),
              let facts = plist(info) else { throw Failure.unreadable }
        if flag("Software License Agreement", in: facts) || flag("Encrypted", in: facts) {
            throw Failure.licence
        }
        let mounts = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mounts, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: mounts) }
        guard let attached = UpdateInstaller.runOutput("/usr/bin/hdiutil", [
            "attach", "-plist", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountrandom", mounts.path,
            source.path
        ]), let entities = plist(attached)?["system-entities"] as? [[String: Any]] else { throw Failure.unreadable }
        let devices = entities.compactMap { $0["dev-entry"] as? String }.sorted { $0.count < $1.count }
        defer {
            if let disk = devices.first, !UpdateInstaller.run("/usr/bin/hdiutil", ["detach", disk]) {
                UpdateInstaller.run("/usr/bin/hdiutil", ["detach", "-force", disk])
            }
        }
        let volumes = entities.compactMap { $0["mount-point"] as? String }.map { URL(fileURLWithPath: $0) }
        let app = volumes.lazy.compactMap { volume in
            identifier.flatMap { UpdateInstaller.find($0, in: volume) } ?? topLevelApp(in: volume)
        }.first
        guard let app else { throw Failure.noApplication }
        return try place(app, identifier: identifier, trusted: trusted, into: applications)
    }

    static func place(_ app: URL, identifier: String?, trusted: Bool, into applications: URL) throws -> URL {
        let found = UpdateInstaller.identifier(of: app)
        if let identifier, found?.lowercased() != identifier.lowercased() {
            throw Failure.differentApplication
        }
        if trusted, !UpdateInstaller.passesGatekeeper(app) {
            throw Failure.gatekeeper
        }
        let destination = applications.appendingPathComponent(app.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure.exists(app.deletingPathExtension().lastPathComponent)
        }
        guard FileManager.default.isWritableFile(atPath: applications.path) else { throw Failure.notAllowed }
        guard UpdateInstaller.run("/usr/bin/ditto", [app.path, destination.path]),
              UpdateInstaller.identifier(of: destination)?.lowercased() == found?.lowercased()
        else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.copy
        }
        return destination
    }

    /// The one app at the top of a volume, ignoring links such as the
    /// usual shortcut to Applications.
    static func topLevelApp(in volume: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: volume.path)) ?? []
        let apps = names.sorted().map { volume.appendingPathComponent($0) }.filter { url in
            url.pathExtension == "app"
                && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
        }
        return apps.count == 1 ? apps.first : nil
    }

    static func plist(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func flag(_ key: String, in facts: [String: Any]) -> Bool {
        if let value = facts[key] as? Bool {
            return value
        }
        return facts.values.contains { ($0 as? [String: Any]).map { flag(key, in: $0) } ?? false }
    }
}
