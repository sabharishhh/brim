import Foundation
import BrimCore
import BrimOps

public struct DeveloperCacheScanner: Sendable {

    /// The catalogue. Each one is here because somebody looked it up, not
    /// because its path contains "cache".
    private struct Known {
        let name: String
        let tool: String
        let relativePath: String
        let cost: DeveloperCache.Cost
        let explanation: String
        /// The tool's own cleanup, for the delegated class.
        var cleanupID: String? = nil
    }

    private static let catalogue: [Known] = [
        Known(name: "Derived data", tool: "Xcode",
              relativePath: "Library/Developer/Xcode/DerivedData",
              cost: .rebuilt,
              explanation: "Build products, indexes and module caches for every project you "
                         + "have opened. Xcode rebuilds it. The next build after clearing it "
                         + "is a slow one."),
        Known(name: "Archives", tool: "Xcode",
              relativePath: "Library/Developer/Xcode/Archives",
              cost: .configured,
              explanation: "Builds you archived for distribution, with the symbols needed to "
                         + "read crash reports from them. Nothing recreates these. Keep any "
                         + "that match something you have shipped."),
        Known(name: "Device support", tool: "Xcode",
              relativePath: "Library/Developer/Xcode/iOS DeviceSupport",
              cost: .refetched,
              explanation: "Symbols copied off each iPhone and iPad you have plugged in, one "
                         + "folder per OS version. Xcode fetches them again from the device, "
                         + "which takes a few minutes the first time you reconnect."),
        Known(name: "Simulator devices", tool: "Xcode",
              relativePath: "Library/Developer/CoreSimulator/Devices",
              cost: .configured,
              explanation: "The simulators themselves, with whatever is installed and set up "
                         + "inside them. Clearing this is not a cache clear: you lose the "
                         + "devices and their contents."),
        Known(name: "Simulator caches", tool: "Xcode",
              relativePath: "Library/Developer/CoreSimulator/Caches",
              cost: .rebuilt,
              explanation: "Runtime images and caches the simulator rebuilds on demand."),
        Known(name: "Module cache", tool: "Swift",
              relativePath: "Library/Caches/org.swift.swiftpm",
              cost: .refetched,
              explanation: "Package checkouts and binary artefacts Swift Package Manager has "
                         + "downloaded. Fetched again on the next resolve."),
        Known(name: "Package cache", tool: "npm",
              relativePath: ".npm/_cacache",
              cost: .refetched,
              explanation: "Every package tarball npm has downloaded. Re-downloaded when "
                         + "something needs them.",
              cleanupID: "npm.cache"),
        Known(name: "Store", tool: "pnpm",
              relativePath: "Library/pnpm/store",
              cost: .refetched,
              explanation: "pnpm's shared package store. Projects on this Mac link into it, "
                         + "so clearing it means the next install re-downloads everything.",
              cleanupID: "pnpm.store"),
        Known(name: "Wheel cache", tool: "pip",
              relativePath: "Library/Caches/pip",
              cost: .refetched,
              explanation: "Built wheels and downloaded packages. pip fetches or rebuilds "
                         + "them as needed.",
              cleanupID: "pip.cache"),
        Known(name: "Registry and builds", tool: "Cargo",
              relativePath: ".cargo/registry",
              cost: .refetched,
              explanation: "Crates Cargo has downloaded and the index it resolves against. "
                         + "Restored on the next build.",
              cleanupID: "cargo.cache"),
        Known(name: "Module cache", tool: "Go",
              relativePath: "go/pkg/mod",
              cost: .refetched,
              explanation: "Every module version Go has downloaded. Re-fetched on demand, and "
                         + "`go clean -modcache` is the tool's own way to do this.",
              cleanupID: "go.modcache"),
        Known(name: "Downloads", tool: "Homebrew",
              relativePath: "Library/Caches/Homebrew",
              cost: .refetched,
              explanation: "Bottles and source archives Homebrew has downloaded. It keeps "
                         + "these after installing and never needs them again unless you "
                         + "reinstall the same version.",
              cleanupID: "homebrew.cleanup"),
        Known(name: "Build cache", tool: "Gradle",
              relativePath: ".gradle/caches",
              cost: .refetched,
              explanation: "Dependencies and build outputs Gradle has cached. Rebuilt and "
                         + "re-downloaded on the next build.",
              cleanupID: "gradle.cache"),
        Known(name: "Local repository", tool: "Maven",
              relativePath: ".m2/repository",
              cost: .refetched,
              explanation: "Every artefact Maven has downloaded. Restored from the remote "
                         + "repositories when a build needs them."),
        Known(name: "Build cache", tool: "Docker",
              relativePath: "Library/Containers/com.docker.docker/Data/vms",
              cost: .configured,
              explanation: "Docker's virtual machine disk, holding your images, containers "
                         + "and volumes. This is data, not a cache. Use Docker's own tools "
                         + "to prune it.")
    ]

    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func scan() async -> [DeveloperCache] {
        let fm = FileManager.default
        return Self.catalogue.compactMap { known -> DeveloperCache? in
            let url = home.appendingPathComponent(known.relativePath)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }

            let size = Self.size(of: url)
            guard size > 0 else { return nil }

            return DeveloperCache(
                name: known.name, tool: known.tool, url: url,
                sizeBytes: size, cost: known.cost, explanation: known.explanation,
                cleanupID: known.cleanupID,
                cleanupCommand: known.cleanupID.flatMap { ToolCleanup.command(id: $0)?.displayed }
            )
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: keys)
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
