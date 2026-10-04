import BrimCore
import Foundation

/// Versions of a command line tool that nothing runs any more.
///
/// Tools that update themselves often keep each release in a `versions`
/// folder and point the command at one of them: `~/.local/bin/claude` is a
/// link to `~/.local/share/claude/versions/2.1.260`. Every other release in
/// that folder is unused, and the evidence is exact rather than inferred:
/// which version the command runs, and that no link names the rest.
///
/// The rule only speaks where the link does. A tool that picks its version
/// some other way, from a shell hook or a project file the way nvm and mise
/// do, leaves no link, so nothing in its folder is offered. Every link into
/// the folder counts as in use, from the command folders and from inside
/// the versions folder itself, so a `current` or `latest` pointer protects
/// what it points at. Only folders in the home folder are read, and only
/// while the command still resolves; a broken command is a different
/// finding, and no version is spare when it is not clear which one runs.
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

    /// The `versions` folder a path runs through, and the version named in
    /// it: `…/claude/versions/2.1.260/bin/claude` gives
    /// (`…/claude/versions`, `2.1.260`). The last `versions` component wins.
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
