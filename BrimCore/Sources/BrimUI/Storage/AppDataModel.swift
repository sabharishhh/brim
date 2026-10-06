import BrimCore
import BrimProtocol
import Combine
import Foundation

/// One installed application and the space it takes: its bundle, and the
/// data it keeps outside it.
public struct AppData: Identifiable, Sendable, Equatable {
    public let name: String
    public let bundlePath: String
    public let bundleBytes: Int64
    public let dataBytes: Int64

    public var id: String {
        bundlePath
    }

    public var totalBytes: Int64 {
        bundleBytes + dataBytes
    }

    public init(name: String, bundlePath: String, bundleBytes: Int64, dataBytes: Int64) {
        self.name = name
        self.bundlePath = bundlePath
        self.bundleBytes = bundleBytes
        self.dataBytes = dataBytes
    }
}

/// Turns each application's footprint into data no other row counts.
///
/// Measured on this Mac, adding up footprints as they came would have
/// counted 13 GB twice: Claude and the "Claude Code URL Handler" app inside
/// its folder both claim `~/.claude`, Application Support and the rest. A
/// folder is counted once, for the claimant with the larger bundle, so the
/// handler is not listed as a 13 GB app. A folder inside one already
/// counted is not counted again, and what the Developer caches row counts
/// is taken out, so the rows on Space never overlap.
public enum AppDataLedger {
    public struct App: Sendable, Equatable {
        public let name: String
        public let bundlePath: String
        public let bundleBytes: Int64

        public init(name: String, bundlePath: String, bundleBytes: Int64) {
            self.name = name
            self.bundlePath = bundlePath
            self.bundleBytes = bundleBytes
        }
    }

    /// One location in one application's footprint.
    public struct Claim: Sendable, Equatable {
        public let bundlePath: String
        public let path: String
        public let bytes: Int64

        public init(bundlePath: String, path: String, bytes: Int64) {
            self.bundlePath = bundlePath
            self.path = path
            self.bytes = bytes
        }
    }

    /// A place counted elsewhere on the page, with its size.
    public struct Counted: Sendable, Equatable {
        public let path: String
        public let bytes: Int64

        public init(path: String, bytes: Int64) {
            self.path = path
            self.bytes = bytes
        }
    }

    public static func attribute(apps: [App], claims: [Claim], countedElsewhere: [Counted]) -> [AppData] {
        let byBundle = Dictionary(apps.map { ($0.bundlePath, $0) }, uniquingKeysWith: { first, _ in first })
        let bundles = apps.map(\.bundlePath)

        // Each path once, to the claimant with the larger bundle.
        var owner: [String: Claim] = [:]
        for claim in claims where !bundles.contains(where: { inside(claim.path, $0) }) {
            guard let current = owner[claim.path] else {
                owner[claim.path] = claim
                continue
            }
            let mine = byBundle[claim.bundlePath]?.bundleBytes ?? 0
            let theirs = byBundle[current.bundlePath]?.bundleBytes ?? 0
            if mine > theirs || (mine == theirs && claim.bundlePath < current.bundlePath) {
                owner[claim.path] = claim
            }
        }

        // Shortest first, so a folder is kept before anything inside it.
        var kept: [String] = []
        var data: [String: Int64] = [:]
        for path in owner.keys.sorted(by: { $0.count < $1.count }) {
            guard let claim = owner[path], !kept.contains(where: { inside(path, $0) }),
                  !countedElsewhere.contains(where: { inside(path, $0.path) }) else { continue }
            kept.append(path)
            let within = countedElsewhere.filter { inside($0.path, path) }.reduce(0) { $0 + $1.bytes }
            data[claim.bundlePath, default: 0] += max(0, claim.bytes - within)
        }

        return apps.map {
            AppData(
                name: $0.name, bundlePath: $0.bundlePath, bundleBytes: $0.bundleBytes,
                dataBytes: data[$0.bundlePath] ?? 0
            )
        }
    }

    /// Whether `path` is `folder` or somewhere inside it.
    static func inside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}

/// Measures every installed application's data for Space.
///
/// Uses the same inspection as the Apps inspector, so a folder is an app's
/// here for the reasons it is an app's there. Three at a time: on this Mac
/// nineteen apps took thirteen seconds one after another, Xcode five of
/// them.
@MainActor
public final class AppDataModel: ObservableObject {
    @Published public private(set) var apps: [AppData] = []
    @Published public private(set) var isMeasuring = false
    @Published public private(set) var measured = 0
    @Published public private(set) var toMeasure = 0
    /// Set once a measurement has finished, whatever it found.
    @Published public private(set) var hasMeasured = false
    /// Some search did not finish, so the figures are floors.
    @Published public private(set) var isIncomplete = false

    public init() {}

    public var dataBytes: Int64 {
        apps.reduce(0) { $0 + $1.dataBytes }
    }

    public func measure(
        service: any BrimServiceProtocol, applications: [InstalledApplication], developer: [DeveloperCache]
    ) async {
        guard !isMeasuring else { return }
        let installed = applications.filter { !$0.isSystemProtected && !$0.url.path.hasPrefix("/Volumes/") }
        isMeasuring = true
        measured = 0
        toMeasure = installed.count
        defer { isMeasuring = false }

        var claims: [AppDataLedger.Claim] = []
        var incomplete = false
        await withTaskGroup(of: (InstalledApplication, Footprint?).self) { group in
            var pending = installed[...]
            func next() {
                guard let app = pending.popFirst() else { return }
                group.addTask { await (app, try? service.inspect(identity: app.identity)) }
            }
            for _ in 0 ..< 3 {
                next()
            }
            for await (app, footprint) in group {
                measured += 1
                if let footprint {
                    incomplete = incomplete || footprint.completeness != .complete || footprint.unreadableEntries > 0
                    claims += footprint.items.map {
                        .init(bundlePath: Self.path(app.url), path: Self.path($0.evidence.url), bytes: $0.sizeBytes)
                    }
                } else {
                    incomplete = true
                }
                next()
            }
        }
        guard !Task.isCancelled else { return }
        apps = AppDataLedger.attribute(
            apps: installed.map {
                .init(name: $0.name, bundlePath: Self.path($0.url), bundleBytes: $0.bundleSizeBytes)
            },
            claims: claims,
            countedElsewhere: developer.map { .init(path: Self.path($0.url), bytes: $0.sizeBytes) }
        )
        isIncomplete = incomplete
        hasMeasured = true
    }

    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
