import BrimCore
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// Lists every place software puts things, for one side of a recording.
///
/// Directory listings only, no sizes and no walks, so a snapshot of the
/// whole inventory takes a fraction of a second. The locations are
/// `LocationInventory`'s, the same table removal and Remnants use, so a
/// recording looks where Brim would later look.
public struct InstallSnapshotReader: Sendable {
    let root: FileSystemRoot
    let backgroundItems: @Sendable () -> [BTMRecord]?
    /// Brim's own names and identifier, lower case, read from its bundle.
    let own: Set<String>

    public init(root: FileSystemRoot = FileSystemRoot(), own: Set<String> = [],
                backgroundItems: @escaping @Sendable () -> [BTMRecord]? = { BTMStore().records() }) {
        self.root = root
        self.own = Set(own.map { $0.lowercased() })
        self.backgroundItems = backgroundItems
    }

    /// What Brim itself is called, from its own bundle, so nothing here
    /// carries a list of its identifiers (`SafetyChecker` does the same).
    public static func ownNames(of bundle: URL) -> Set<String> {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return Set([info?["CFBundleIdentifier"] as? String, info?["CFBundleName"] as? String,
                    bundle.deletingPathExtension().lastPathComponent].compactMap { $0?.lowercased() })
    }

    /// Where a developer's folder holds each product's, one level more is
    /// read: `Application Support/Vendor/Product`, an Applications folder's
    /// suite folders.
    static let deeper: Set<FileSystemRoot.Domain> = [
        .userApplicationSupport, .systemApplicationSupport, .applications, .userApplications
    ]

    /// Temporary and per-boot folders change constantly whatever is
    /// installed; volumes and other accounts are not this install's.
    static let skipped: Set<FileSystemRoot.Domain> = [.volumes, .users, .tempDirs, .darwinUserTemp]

    public func take(at date: Date = Date()) -> InstallSnapshot {
        var paths = Set<String>()
        var apps: [String: InstallSnapshot.AppMark] = [:]
        var unreadable: [String] = []
        var seen = Set<String>()
        // The Applications folders are not in the inventory, which is about
        // what apps leave elsewhere; a recording needs to see the app arrive.
        let domains = [FileSystemRoot.Domain.applications, .userApplications]
            + LocationInventory.standard.locations.map(\.domain)
        for domain in domains where !Self.skipped.contains(domain) {
            let folder = root.url(for: domain)
            guard seen.insert(folder.path).inserted else { continue }
            for entry in list(folder, unreadable: &unreadable) {
                // The rest of the home folder is the person's own.
                if domain == .userHomeDotFolders, !entry.hasPrefix(".") {
                    continue
                }
                guard !Self.isNoise(entry), !isOwn(entry) else { continue }
                let url = folder.appendingPathComponent(entry)
                paths.insert(url.path)
                if entry.hasSuffix(".app") {
                    apps[url.path] = Self.mark(url)
                } else if Self.deeper.contains(domain), InstallerReader.isFolder(url) {
                    for inner in list(url, unreadable: &unreadable) {
                        let child = url.appendingPathComponent(inner)
                        paths.insert(child.path)
                        if inner.hasSuffix(".app") {
                            apps[child.path] = Self.mark(child)
                        }
                    }
                }
            }
        }
        let background = readBackground(unreadable: &unreadable)
        return InstallSnapshot(takenAt: date, paths: paths, apps: apps, backgroundItems: background,
                               unreadable: unreadable.sorted())
    }

    /// macOS writes its own entries constantly, whatever is being
    /// installed. A folder a system service keeps for an app
    /// (`com.apple.WebKit.Networking+com.example.app`) is the app's, so it
    /// stays.
    static func isNoise(_ name: String) -> Bool {
        if name == ".DS_Store" || name == ".localized" || name == ".Trash" {
            return true
        }
        return name.lowercased().hasPrefix("com.apple.") && !name.contains("+")
    }

    /// Brim's own folders change because Brim is recording, and its root
    /// owned one cannot even be listed.
    func isOwn(_ name: String) -> Bool {
        let lower = name.lowercased()
        return own.contains(lower) || own.contains { lower.hasPrefix($0 + ".") }
    }

    /// The background items macOS has accepted, by the record's own key.
    private func readBackground(unreadable: inout [String]) -> [String: InstallSnapshot.BackgroundMark] {
        guard let records = backgroundItems() else {
            unreadable.append("Login items and background services")
            return [:]
        }
        var background: [String: InstallSnapshot.BackgroundMark] = [:]
        for record in records {
            let path = record.rawURLPath.flatMap { $0.hasPrefix("/") ? $0 : nil }
            background[record.uuid] = InstallSnapshot.BackgroundMark(
                label: record.name ?? record.identifier ?? record.uuid,
                bundleIdentifier: record.bundleIdentifier ?? record.parentIdentifier, path: path
            )
        }
        return background
    }

    private func list(_ folder: URL, unreadable: inout [String]) -> [String] {
        switch DirectoryEntries.read(folder) {
        case let .listed(names): return names
        case .refused:
            unreadable.append(folder.path)
            return []
        case .absent: return []
        }
    }

    static func mark(_ bundle: URL) -> InstallSnapshot.AppMark {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let names = [
            bundle.deletingPathExtension().lastPathComponent, info?["CFBundleName"] as? String,
            info?["CFBundleDisplayName"] as? String, info?["CFBundleExecutable"] as? String
        ].compactMap(\.self)
        return InstallSnapshot.AppMark(
            identifier: info?["CFBundleIdentifier"] as? String,
            version: info?["CFBundleShortVersionString"] as? String ?? info?["CFBundleVersion"] as? String,
            names: Array(Set(names)).sorted()
        )
    }
}
