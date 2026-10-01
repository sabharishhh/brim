import BrimCore
import BrimOps
import Foundation

public struct DeveloperCacheScanner: Sendable {
    private let home: URL
    private let darwinCache: URL
    private let projects: ProjectBuildScanner?
    private let updateDownloads: UpdateDownloadScanner?
    private let oldVersions: OldVersionsScanner?
    private let environment: [String: String]
    private let excludedFolders: [URL]
    private let measure: Measure

    typealias Measure = @Sendable (URL, ScanBudget) async -> ArtifactSize

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        darwinCache: URL = FileSystemRoot().url(for: .darwinUserCache),
        projects: ProjectBuildScanner? = ProjectBuildScanner(),
        updates: UpdateDownloadScanner? = UpdateDownloadScanner(),
        oldVersions: OldVersionsScanner? = OldVersionsScanner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        excludedFolders: [URL] = []
    ) {
        self.home = home
        self.darwinCache = darwinCache
        self.projects = projects
        updateDownloads = updates
        self.oldVersions = oldVersions
        self.environment = environment
        self.excludedFolders = excludedFolders
        measure = Self.measureArtifact
    }

    /// Controlled measurement for scanner regression tests. No mutation path
    /// or tool command is injectable through this read-only seam.
    init(home: URL, darwinCache: URL, measure: @escaping Measure) {
        self.home = home
        self.darwinCache = darwinCache
        projects = nil
        updateDownloads = nil
        oldVersions = nil
        environment = [:]
        excludedFolders = []
        self.measure = measure
    }

    /// Every path this catalogue accounts for, so Leftovers leaves them to
    /// Developer instead of counting them a second time.
    public static func claimedPaths(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        darwinCache: URL = FileSystemRoot().url(for: .darwinUserCache),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<String> {
        Set(catalogue.flatMap {
            urls(of: $0, home: home, darwinCache: darwinCache, environment: environment)
                .map(\.standardizedFileURL.path)
        })
    }

    private static func url(of known: Known, home: URL, darwinCache: URL) -> URL {
        (known.inDarwinCache ? darwinCache : home).appendingPathComponent(known.relativePath)
    }

    /// Re-derive the disposal rule independently of the selected UI row.
    /// Positive cache rules require an exact root. Tool-managed and stateful
    /// stores protect their children as well, so a direct child target cannot
    /// bypass the store's disposal rule.
    public static func classification(
        at target: URL, home: URL, darwinCache: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ArtifactClassification? {
        let path = target.standardizedFileURL.path
        var overlapsToolStore = false
        for known in catalogue where known.cost == .refetched || known.cost == .configured {
            let roots = urls(of: known, home: home, darwinCache: darwinCache, environment: environment)
            for root in roots where PathExistence.exists(at: root) {
                if ArtifactSizer.rootsOverlap(target, root) {
                    if known.cost == .configured {
                        return .stateful
                    }
                    overlapsToolStore = true
                }
            }
        }
        if overlapsToolStore {
            return .toolManaged
        }
        guard ProjectBuildScanner.isRealFolder(target) else { return nil }
        guard let known = catalogue.first(where: {
            urls(of: $0, home: home, darwinCache: darwinCache, environment: environment)
                .contains { $0.standardizedFileURL.path == path }
        }) else { return nil }
        guard !known.cost.isBrimRemovable || hasPositiveScope(
            target,
            known: known,
            home: home,
            darwinCache: darwinCache
        )
        else { return nil }
        return classification(of: known)
    }

    private static func classification(of known: Known) -> ArtifactClassification {
        switch known.cost {
        case .rebuilt: .rebuildableCache
        case .refetched: .toolManaged
        case .restored: .dependencyStore
        case .configured: .stateful
        }
    }

    private static func urls(
        of known: Known, home: URL, darwinCache: URL, environment: [String: String]
    ) -> [URL] {
        var locations = [url(of: known, home: home, darwinCache: darwinCache)]
        let configured = known.environmentVariable.flatMap { environment[$0] }
            .flatMap { configuredURL($0, home: home) }
        if let configured {
            locations.append(known.configuredSuffix.map { configured.appendingPathComponent($0) } ?? configured)
        }
        // Yarn 1 also observes XDG_CACHE_HOME on macOS.
        let yarnCache = environment["XDG_CACHE_HOME"].flatMap { configuredURL($0, home: home) }
        if known.tool == "Yarn Classic", let yarnCache {
            locations.append(yarnCache.appendingPathComponent("yarn"))
        }
        return locations
    }

    private static func configuredURL(_ value: String, home: URL) -> URL? {
        let path = value.hasPrefix("~/") ? home.appendingPathComponent(String(value.dropFirst(2))).path : value
        guard path.hasPrefix("/"), !path.contains("\u{0}") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let homePath = home.standardizedFileURL.path
        // A broad environment setting must not turn a whole home or Library
        // into a tool-store row, or hide it from Remnants.
        let broad = [homePath, homePath + "/Library", homePath + "/Library/Caches",
                     homePath + "/.cache", homePath + "/.config"]
        guard url.path.hasPrefix(homePath + "/"), !broad.contains(url.path) else { return nil }
        return url
    }

    public func scan() async -> [DeveloperCache] {
        var latest: [DeveloperCache] = []
        for await caches in await updates() {
            latest = caches
        }
        return latest
    }

    /// A bounded producer, cancelled when the consumer leaves. The first
    /// snapshot contains discovered rows before any recursive measurement.
    public func updates() async -> AsyncStream<[DeveloperCache]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                await scan(into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @concurrent
    private func scan(into continuation: AsyncStream<[DeveloperCache]>.Continuation) async {
        guard !Task.isCancelled else { return }
        var rows = discoverKnown()
        continuation.yield(rows)
        await measureRows(&rows, into: continuation)
        guard !Task.isCancelled else { return }

        // Project discovery is separate from recursive sizing. Legacy update
        // and version readers remain bounded by the shared measurement helper.
        let discovered = projects?.discover(home: home, excluding: excludedFolders) ?? []
        rows += discovered.filter { !isExcluded($0.url) }
        continuation.yield(rows)
        await measureRows(&rows, into: continuation)
        guard !Task.isCancelled else { return }
        rows += (updateDownloads?.scan(home: home) ?? []).filter { !isExcluded($0.url) }
        continuation.yield(rows)
        guard !Task.isCancelled else { return }
        rows += (oldVersions?.scan(home: home) ?? []).filter { !isExcluded($0.url) }
        continuation.yield(rows)
    }

    private func discoverKnown() -> [DeveloperCache] {
        var seen = Set<String>()
        return Self.catalogue.flatMap { known in
            Self.urls(of: known, home: home, darwinCache: darwinCache, environment: environment)
                .compactMap { url -> DeveloperCache? in
                    guard !Task.isCancelled, !isExcluded(url), seen.insert(url.standardizedFileURL.path).inserted,
                          ProjectBuildScanner.isRealFolder(url),
                          !known.cost.isBrimRemovable || Self.hasPositiveScope(
                              url, known: known, home: home, darwinCache: darwinCache
                          ) else { return nil }
                    return DeveloperCache(
                        name: known.name, tool: known.tool, url: url, sizeBytes: 0,
                        cost: known.cost, explanation: known.explanation,
                        cleanupID: known.cleanupID,
                        cleanupCommand: known.cleanupID.flatMap { ToolCleanup.command(id: $0)?.displayed }
                            ?? known.manualCommand,
                        manualCleanupReason: known.manualReason
                            ?? known.cleanupID.flatMap { ToolCleanup.command(id: $0)?.manualReason },
                        sizeMeasurement: .pending, artifactClassification: Self.classification(of: known)
                    )
                }
        }
    }

    private func isExcluded(_ url: URL) -> Bool {
        excludedFolders.contains { ArtifactSizer.rootsOverlap(url, $0) }
    }

    private func measureRows(
        _ rows: inout [DeveloperCache], into continuation: AsyncStream<[DeveloperCache]>.Continuation
    ) async {
        let pending = rows.filter { $0.sizeMeasurement?.state == .pending }
        let budget = ScanBudget(total: 60)
        await withTaskGroup(of: DeveloperCache.self) { group in
            var next = 0
            for _ in 0 ..< min(4, pending.count) {
                let row = pending[next]
                next += 1
                group.addTask { await row.measured(using: measure(row.url, budget)) }
            }
            while let measured = await group.next() {
                if Task.isCancelled {
                    group.cancelAll(); return
                }
                if let index = rows.firstIndex(where: { $0.id == measured.id }) {
                    if measured.sizeMeasurement?.isEmpty == true {
                        rows.remove(at: index)
                    } else {
                        rows[index] = measured
                    }
                }
                continuation.yield(rows)
                if next < pending.count {
                    let row = pending[next]
                    next += 1
                    group.addTask { await row.measured(using: measure(row.url, budget)) }
                }
            }
        }
    }

    @concurrent
    private static func measureArtifact(_ url: URL, _ budget: ScanBudget) async -> ArtifactSize {
        ArtifactSizer.measure(at: url, budget: budget)
    }

    /// Compatibility for readers still migrating to explicit measurement status.
    static func size(of url: URL) -> Int64 {
        ArtifactSizer.measure(at: url).allocatedBytes
    }
}
