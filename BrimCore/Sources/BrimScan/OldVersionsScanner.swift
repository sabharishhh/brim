import BrimCore
import Foundation

/// Versions of a command line tool that nothing runs any more. A tool that
/// updates itself may keep each release in a `versions` folder and link the
/// command to one; every other release there is unused. Only spoken where a
/// link says which version runs: any link into the folder counts as in use,
/// and nothing is offered when the command is broken or its version unclear.
public struct OldVersionsScanner: Sendable {
    private let commandFolders: [URL]

    public init(commandFolders: [URL]? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.commandFolders = commandFolders ?? [
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent("bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin")
        ]
    }

    public func scan(home: URL) -> [DeveloperCache] {
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        // Versions folder, to the versions in use and the commands using them.
        var inUse: [String: (versions: Set<String>, commands: [String: String])] = [:]
        for folder in commandFolders {
            for link in Self.children(of: folder) {
                if Task.isCancelled {
                    return []
                }
                guard let target = Self.linkTarget(link),
                      FileManager.default.fileExists(atPath: target.path),
                      let (versions, version) = Self.versionsFolder(of: target),
                      versions.path.hasPrefix(homePath)
                else { continue }
                inUse[versions.path, default: ([], [:])].versions.insert(version)
                inUse[versions.path, default: ([], [:])].commands[link.lastPathComponent] = version
            }
        }

        var found: [DeveloperCache] = []
        for (path, use) in inUse {
            if Task.isCancelled {
                return found
            }
            let versions = URL(fileURLWithPath: path)
            var protected = use.versions
            let entries = Self.children(of: versions)
            // A pointer inside the folder, such as `current`, protects its
            // target, and is never offered itself.
            for entry in entries where Self.isLink(entry) {
                protected.insert(entry.lastPathComponent)
                if let target = Self.linkTarget(entry), let (_, version) = Self.versionsFolder(of: target) {
                    protected.insert(version)
                }
            }
            let tool = versions.deletingLastPathComponent().lastPathComponent
            let running = use.commands.sorted { $0.key < $1.key }
                .map { "\($0.key) runs \($0.value)" }.joined(separator: ", ")
            for entry in entries where !protected.contains(entry.lastPathComponent) {
                let size = ArtifactSizer.measure(at: entry)
                guard !size.isEmpty else { continue }
                found.append(DeveloperCache(
                    name: "Version \(entry.lastPathComponent)", tool: tool, url: entry, sizeBytes: size.allocatedBytes,
                    cost: .restored,
                    explanation: "Not used: \(running), and nothing links to \(entry.lastPathComponent). "
                        + "Moved to the Trash to preserve local changes.",
                    versionInUse: use.versions.sorted().joined(separator: ", "),
                    sizeMeasurement: size, artifactClassification: .dependencyStore
                ))
            }
        }
        return found.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// The `versions` folder a path runs through and the version in it:
    /// `.../claude/versions/2.1.260/bin/claude` gives
    /// (`.../claude/versions`, `2.1.260`). The last `versions` component wins.
    static func versionsFolder(of path: URL) -> (URL, String)? {
        let parts = path.standardizedFileURL.pathComponents
        guard let index = parts.lastIndex(of: "versions"), index + 1 < parts.count, index > 1 else { return nil }
        let folder = NSString.path(withComponents: Array(parts[...index]))
        return (URL(fileURLWithPath: folder), parts[index + 1])
    }

    /// Where a link points, resolved fully, or nil for anything else.
    static func linkTarget(_ url: URL) -> URL? {
        guard isLink(url) else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    static func children(of folder: URL) -> [URL] {
        guard case let .listed(names) = DirectoryEntries.read(folder) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.map { folder.appendingPathComponent($0) }
    }
}
