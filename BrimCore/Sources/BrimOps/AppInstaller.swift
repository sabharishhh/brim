import BrimCore
import Foundation

/// Puts an application the person has looked inside into Applications.
///
/// Only an app, loose or in a disk image: a package's scripts are its
/// developer's to run, so packages open in Apple's Installer instead and
/// Brim records around it. What is copied is checked again against what the
/// preview showed, because the file could have changed in between: the same
/// identifier, and Gatekeeper's approval when the preview said it had it.
///
/// Once Gatekeeper accepts the copy, its quarantine is removed. macOS runs
/// a quarantined app from a hidden read-only copy (App Translocation)
/// unless a person moved it in Finder, and clicking Open on the first
/// launch warning does not change that: Figma's installer app, run from
/// there, could not replace itself and asked to be moved to Applications.
/// Brim has made the check the warning stands for, as Apple's Installer and
/// the App Store have, and they leave no quarantine either. An app
/// Gatekeeper does not accept keeps it, so macOS still warns or blocks.
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
    ///   - progress: how much of the app has been copied, from 0 to 1.
    public static func install(
        from source: URL, identifier: String?, trusted: Bool,
        applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws -> URL {
        try install(from: source, identifier: identifier, trusted: trusted, applications: applications,
                    accepts: { UpdateInstaller.passesGatekeeper($0) }, progress: progress)
    }

    /// `accepts` is Gatekeeper's verdict, replaceable so a test can reach
    /// the accepted path without a notarised app.
    static func install(
        from source: URL, identifier: String?, trusted: Bool, applications: URL,
        accepts: (URL) -> Bool, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws -> URL {
        if source.pathExtension.lowercased() == "app" {
            return try place(source, identifier: identifier, trusted: trusted, into: applications,
                             accepts: accepts, progress: progress)
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
        return try place(app, identifier: identifier, trusted: trusted, into: applications,
                         accepts: accepts, progress: progress)
    }

    static func place(
        _ app: URL, identifier: String?, trusted: Bool, into applications: URL,
        accepts: (URL) -> Bool, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws -> URL {
        let found = UpdateInstaller.identifier(of: app)
        if let identifier, found?.lowercased() != identifier.lowercased() {
            throw Failure.differentApplication
        }
        let accepted = accepts(app)
        if trusted, !accepted {
            throw Failure.gatekeeper
        }
        let destination = applications.appendingPathComponent(app.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure.exists(app.deletingPathExtension().lastPathComponent)
        }
        guard FileManager.default.isWritableFile(atPath: applications.path) else { throw Failure.notAllowed }
        guard copy(app, to: destination, progress: progress),
              UpdateInstaller.identifier(of: destination)?.lowercased() == found?.lowercased()
        else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.copy
        }
        if accepted {
            clearQuarantine(in: destination)
        }
        return destination
    }

    /// Removes the quarantine from the bundle and everything in it, without
    /// following links. Best effort: the bundle's own is what macOS reads
    /// to decide whether to translocate.
    static func clearQuarantine(in bundle: URL) {
        removexattr(bundle.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let items = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil)
        while let item = items?.nextObject() as? URL {
            removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    /// `ditto`, with how much of the app has arrived measured while it
    /// runs: the bytes at the destination against the bytes of the app.
    static func copy(_ app: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) -> Bool {
        let total = max(ArtifactSizer.measure(at: app).logicalBytes, 1)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [app.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        progress(0)
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.25)
            let copied = ArtifactSizer.measure(at: destination).logicalBytes
            progress(min(0.99, Double(copied) / Double(total)))
        }
        guard process.terminationStatus == 0 else { return false }
        progress(1)
        return true
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
