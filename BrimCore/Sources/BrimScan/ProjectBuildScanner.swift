import BrimCore
import Foundation

/// Build output inside a project: `target` beside `Cargo.toml`, `.build`
/// beside `Package.swift`, `node_modules` beside `package.json`.
///
/// The largest thing any tool left on the Mac this was written on was a
/// Rust project's `target` folder, 20 GB, and no list of tool caches can
/// find it, because it lives wherever the project does. A folder counts
/// only when the file that makes it rebuildable sits beside it, so a
/// folder that merely happens to be called `build` is never offered. When
/// each project was last built is shown, and nothing is ticked for you:
/// clearing a project you are working on costs you a full build.
public struct ProjectBuildScanner: Sendable {
    struct Kind: Sendable {
        let markers: [String]
        let folders: [String]
        let tool: String
        let rebuild: String
        /// A lock file that must sit beside the marker, so reinstalling gives
        /// back the same packages. Empty when the build needs none.
        var lockFiles: [String] = []
    }

    static let kinds: [Kind] = [
        Kind(markers: ["Cargo.toml"], folders: ["target"], tool: "Rust", rebuild: "cargo build"),
        Kind(markers: ["Package.swift"], folders: [".build"], tool: "Swift", rebuild: "swift build"),
        Kind(markers: ["package.json"], folders: ["node_modules", ".next"], tool: "Node", rebuild: "npm install",
             lockFiles: ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"]),
        Kind(markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
             folders: ["build", ".gradle"], tool: "Gradle", rebuild: "the next Gradle build"),
        Kind(markers: ["pubspec.yaml"], folders: [".dart_tool", "build"], tool: "Flutter", rebuild: "flutter pub get"),
        Kind(markers: ["pyproject.toml", "requirements.txt"], folders: [".venv", "venv"], tool: "Python",
             rebuild: "reinstalling the project's packages"),
        Kind(markers: ["Podfile"], folders: ["Pods"], tool: "CocoaPods", rebuild: "pod install",
             lockFiles: ["Podfile.lock"]),
        Kind(markers: ["pom.xml"], folders: ["target"], tool: "Maven", rebuild: "mvn package"),
        Kind(markers: ["mix.exs"], folders: ["_build", "deps"], tool: "Elixir", rebuild: "mix compile")
    ]

    /// Where projects are looked for when Spotlight cannot answer.
    static let usualFolders = ["Developer", "Projects", "Code", "code", "src", "dev", "work", "GitHub", "Documents"]

    public typealias Search = @Sendable (_ markers: [String], _ home: URL) -> [URL]?

    private let search: Search

    public init(search: @escaping Search = ProjectBuildScanner.spotlight) {
        self.search = search
    }

    public func scan(home: URL) -> [DeveloperCache] {
        let markers = Self.kinds.flatMap(\.markers)
        let files = search(markers, home) ?? Self.walk(markers, home: home)
        var seen = Set<String>()
        var found: [DeveloperCache] = []
        for file in files where Self.isProjectFile(file, home: home) {
            let project = file.deletingLastPathComponent()
            guard let kind = Self.kinds.first(where: { $0.markers.contains(file.lastPathComponent) }) else { continue }
            if !kind.lockFiles.isEmpty, !kind.lockFiles.contains(where: {
                FileManager.default.fileExists(atPath: project.appendingPathComponent($0).path)
            }) { continue }
            for folder in kind.folders {
                let output = project.appendingPathComponent(folder)
                guard seen.insert(output.path).inserted, Self.isRealFolder(output) else { continue }
                let size = DeveloperCacheScanner.size(of: output)
                guard size > 0 else { continue }
                found.append(DeveloperCache(
                    name: "Build output", tool: project.lastPathComponent, url: output, sizeBytes: size,
                    cost: .rebuilt,
                    explanation: "\(kind.tool) build output in \(project.path.replacingOccurrences(of: home.path, with: "~")). "
                        + "Made again by \(kind.rebuild).",
                    lastBuilt: Self.lastChanged(output)
                ))
            }
        }
        return found.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// A project's own file, not one inside a dependency, a build, the
    /// Library, the Trash or a hidden folder.
    static func isProjectFile(_ file: URL, home: URL) -> Bool {
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(home.standardizedFileURL.path + "/") else { return false }
        let parts = path.dropFirst(home.standardizedFileURL.path.count + 1).split(separator: "/")
        let excluded: Set<Substring> = ["Library", "node_modules", "target", "build", "Pods", "deps", "_build",
                                        "Applications", "Pictures", "Music", "Movies"]
        return !parts.dropLast().contains { $0.hasPrefix(".") || excluded.contains($0) }
    }

    static func isRealFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// The newest change to the folder or anything at its first level, which
    /// is where a build writes.
    static func lastChanged(_ folder: URL) -> Date {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var newest = (try? folder.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
        for child in (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [])) ?? [] {
            if let date = (try? child.resourceValues(forKeys: Set(keys)))?.contentModificationDate, date > newest {
                newest = date
            }
        }
        return newest
    }

    /// Spotlight's index, which answers for the whole home folder in well
    /// under a second. Nil when it cannot answer.
    public static let spotlight: Search = { markers, home in
        let query = markers.map { "kMDItemFSName == \"\($0)\"" }.joined(separator: " || ")
        guard let output = ToolOutput.read("/usr/bin/mdfind", ["-onlyin", home.path, query], timeout: 15)
        else { return nil }
        let files = output.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        return files.isEmpty ? nil : files
    }

    /// The folders people keep code in, four levels down.
    static func walk(_ markers: [String], home: URL) -> [URL] {
        let wanted = Set(markers)
        var found: [URL] = []
        for name in usualFolders {
            let top = home.appendingPathComponent(name)
            guard let enumerator = FileManager.default.enumerator(
                at: top, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if enumerator.level > 4 { enumerator.skipDescendants(); continue }
                if ["node_modules", "target", "build", "Pods", ".build"].contains(url.lastPathComponent) {
                    enumerator.skipDescendants(); continue
                }
                if wanted.contains(url.lastPathComponent) { found.append(url) }
            }
        }
        return found
    }
}
