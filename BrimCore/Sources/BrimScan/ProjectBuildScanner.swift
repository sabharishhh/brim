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
        let artifacts: [Artifact]
        let tool: String
    }

    struct Artifact: Sendable {
        let folder: String
        let classification: ArtifactClassification
        let restore: String
        var lockFiles: [String] = []
        var dependency: String?
    }

    static let usualFolders = ["Developer", "Projects", "Code", "code", "src", "dev", "work", "GitHub", "Documents"]
    public typealias Search = @Sendable (_ markers: [String], _ home: URL) -> [URL]?
    private let search: Search

    public init(search: @escaping Search = ProjectBuildScanner.spotlight) {
        self.search = search
    }

    public func scan(home: URL, excluding: [URL] = []) -> [DeveloperCache] {
        discover(home: home, excluding: excluding).compactMap { cache in
            let size = ArtifactSizer.measure(at: cache.url)
            return size.isEmpty ? nil : cache.measured(using: size)
        }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Discovery returns rows before their potentially expensive size walks.
    public func discover(home: URL, excluding: [URL] = []) -> [DeveloperCache] {
        let markers = Self.kinds.flatMap(\.markers)
        let files = search(markers, home) ?? Self.walk(markers, home: home)
        var seen = Set<String>()
        var seenProjects = Set<String>()
        var found: [DeveloperCache] = []
        for file in files where Self.isProjectFile(file, home: home) {
            if Task.isCancelled {
                break
            }
            let project = file.deletingLastPathComponent()
            guard seenProjects.insert(project.standardizedFileURL.path).inserted else { continue }
            for cache in Self.candidates(project: project, home: home) {
                let path = cache.url.standardizedFileURL.path
                guard !excluding.contains(where: { ArtifactSizer.rootsOverlap(cache.url, $0) }),
                      seen.insert(path).inserted else { continue }
                found.append(cache)
            }
        }
        return found
    }

    private static func candidates(project: URL, home: URL) -> [DeveloperCache] {
        let proven = kinds.filter { kind in
            kind.markers.contains { marker in
                let file = project.appendingPathComponent(marker)
                return isProjectFile(file, home: home) && isRealFile(file)
            }
        }
        let entries = proven.flatMap { kind in kind.artifacts.map { (kind, $0) } }.sorted {
            ($0.1.classification == .stateful ? 0 : 1) < ($1.1.classification == .stateful ? 0 : 1)
        }
        var seen = Set<String>()
        return entries.compactMap { kind, artifact in
            let output = project.appendingPathComponent(artifact.folder)
            guard isRealFolder(output), isContained(output, by: project),
                  artifact.lockFiles.isEmpty || artifact.lockFiles.contains(where: {
                      isRealFile(project.appendingPathComponent($0))
                  }), (artifact.dependency.map { hasDependency($0, in: project) } ?? true)
            else { return nil }
            let restore = artifact.folder == "node_modules"
                ? nodeRestore(in: project) : artifact.restore
            guard let restore, seen.insert(output.standardizedFileURL.path).inserted else { return nil }
            let classification = artifact.classification
            let presentation = presentation(for: classification)
            let recovery = classification == .stateful
                ? "Reported only. Restore through \(restore)."
                : "Made again by \(restore)."
            let protection = classification == .dependencyStore
                ? " Moved to the Trash so local changes and offline copies can be recovered." : ""
            return DeveloperCache(
                name: presentation.name, tool: project.lastPathComponent, url: output, sizeBytes: 0,
                cost: presentation.cost,
                explanation: "\(kind.tool) artifact in \(project.path.replacingOccurrences(of: home.path, with: "~")). "
                    + recovery + protection,
                lastBuilt: lastChanged(output), sizeMeasurement: .pending,
                artifactClassification: classification
            )
        }
    }

    private static func presentation(for value: ArtifactClassification) -> (cost: DeveloperCache.Cost, name: String) {
        switch value {
        case .rebuildableOutput: (.rebuilt, "Build output")
        case .rebuildableCache: (.rebuilt, "Build cache")
        case .dependencyStore: (.restored, "Project dependencies and cache")
        case .toolManaged: (.refetched, "Tool-managed store")
        case .stateful, .unknown: (.configured, "Project environment")
        }
    }

    private static func nodeRestore(in project: URL) -> String? {
        let choices = [
            (["package-lock.json", "npm-shrinkwrap.json"], "npm ci"),
            (["pnpm-lock.yaml"], "pnpm install --frozen-lockfile"),
            (["yarn.lock"], "yarn install using the lockfile"),
            (["bun.lock", "bun.lockb"], "bun install --frozen-lockfile")
        ]
        let present = choices.filter { names, _ in names.contains { isRealFile(project.appendingPathComponent($0)) } }
        guard present.count == 1 else { return nil }
        if let declared = packageJSON(in: project)?["packageManager"] as? String {
            let manager = declared.split(separator: "@").first.map(String.init)
            guard let manager, present[0].1.hasPrefix(manager + " ") else { return nil }
        }
        return present[0].1
    }

    private static func hasDependency(_ name: String, in project: URL) -> Bool {
        guard let json = packageJSON(in: project) else { return false }
        return ["dependencies", "devDependencies"].contains { key in
            (json[key] as? [String: Any])?[name] != nil
        }
    }

    private static func packageJSON(in project: URL) -> [String: Any]? {
        let file = project.appendingPathComponent("package.json")
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= 1024 * 1024, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func isRealFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private static func isContained(_ output: URL, by project: URL) -> Bool {
        output.resolvingSymlinksInPath().path.hasPrefix(project.resolvingSymlinksInPath().path + "/")
    }

    /// A project's own file, not one inside a dependency, a build, the
    /// Library, the Trash or a hidden folder.
    static func isProjectFile(_ file: URL, home: URL) -> Bool {
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(home.standardizedFileURL.path + "/"),
              file.resolvingSymlinksInPath().path.hasPrefix(home.resolvingSymlinksInPath().path + "/")
        else { return false }
        let parts = path.dropFirst(home.standardizedFileURL.path.count + 1).split(separator: "/")
        let excluded: Set<Substring> = [
            "Library",
            "node_modules",
            "target",
            "build",
            "Pods",
            "deps",
            "_build",
            "Applications",
            "Pictures",
            "Music",
            "Movies"
        ]
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
            at: folder, includingPropertiesForKeys: keys, options: []
        )) ?? [] {
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
                if Task.isCancelled {
                    return found
                }
                if enumerator.level > 4 {
                    enumerator.skipDescendants(); continue
                }
                if ["node_modules", "target", "build", "Pods", ".build"].contains(url.lastPathComponent) {
                    enumerator.skipDescendants(); continue
                }
                if wanted.contains(url.lastPathComponent) {
                    found.append(url)
                }
            }
        }
        return found
    }
}

extension ProjectBuildScanner {
    /// Used again by service planning. UI eligibility is never the authority.
    public static func classification(at url: URL, home: URL) -> ArtifactClassification? {
        guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
        if hasEnvironmentAncestor(url) || hasEnvironmentAncestor(url.resolvingSymlinksInPath()) {
            return .stateful
        }
        let homes = Set([home.standardizedFileURL.path, home.resolvingSymlinksInPath().path])
        var seen = Set<String>()
        var exactClassification: ArtifactClassification?
        var overlapsToolStore = false
        for start in [url.standardizedFileURL, url.resolvingSymlinksInPath()] {
            var path = start.standardizedFileURL.path
            while homes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                let project = URL(fileURLWithPath: path)
                if seen.insert(path).inserted {
                    if protectsStatefulEntry(target: url, project: project, home: home) {
                        return .stateful
                    }
                    let isStateful = classify(
                        candidates(project: project, home: home),
                        target: url,
                        exact: &exactClassification,
                        overlapsToolStore: &overlapsToolStore
                    )
                    if isStateful {
                        return .stateful
                    }
                }
                guard let parent = parentPath(of: path) else { break }
                path = parent
            }
        }
        return overlapsToolStore ? .toolManaged : exactClassification
    }

    private static func classify(
        _ caches: [DeveloperCache], target: URL,
        exact: inout ArtifactClassification?, overlapsToolStore: inout Bool
    ) -> Bool {
        for cache in caches {
            let overlaps = ArtifactSizer.rootsOverlap(target, cache.url)
            if cache.artifactClassification == .stateful, overlaps {
                return true
            }
            if cache.artifactClassification == .toolManaged, overlaps {
                overlapsToolStore = true
            }
            if sameTarget(cache.url, target) {
                exact = cache.artifactClassification
            }
        }
        return false
    }

    private static func sameTarget(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.path == second.standardizedFileURL.path
            || first.resolvingSymlinksInPath().path == second.resolvingSymlinksInPath().path
    }

    /// Negative protection does not require a removable directory. A linked
    /// environment still owns its contents, even outside the project.
    private static func protectsStatefulEntry(target: URL, project: URL, home: URL) -> Bool {
        kinds.contains { kind in
            guard kind.artifacts.contains(where: { $0.classification == .stateful }),
                  kind.markers.contains(where: {
                      let marker = project.appendingPathComponent($0)
                      return isProjectFile(marker, home: home) && isRealFile(marker)
                  }) else { return false }
            return kind.artifacts.contains { artifact in
                let entry = project.appendingPathComponent(artifact.folder)
                return artifact.classification == .stateful && PathExistence.exists(at: entry)
                    && ArtifactSizer.rootsOverlap(target, entry)
            }
        }
    }

    /// Python creates this marker in a virtual environment. It also protects
    /// direct targets using the resolved location of a project environment.
    private static func hasEnvironmentAncestor(_ target: URL) -> Bool {
        guard target.isFileURL, target.path.hasPrefix("/") else { return false }
        var path = target.standardizedFileURL.path
        while path != "/" {
            let folder = URL(fileURLWithPath: path)
            if isRealFile(folder.appendingPathComponent("pyvenv.cfg")) {
                return true
            }
            guard let parent = parentPath(of: path) else { return false }
            path = parent
        }
        return false
    }

    /// String parents reach the filesystem root monotonically. Foundation
    /// file URL parents can alternate between root and empty path forms.
    private static func parentPath(of path: String) -> String? {
        guard path != "/", path.hasPrefix("/") else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent.hasPrefix("/"), parent.utf8.count < path.utf8.count else { return nil }
        return parent
    }
}
