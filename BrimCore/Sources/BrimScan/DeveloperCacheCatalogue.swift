import BrimCore
import Darwin
import Foundation

extension DeveloperCacheScanner {
    /// The catalogue. Each one is here because somebody looked it up, not
    /// because its path contains "cache".
    struct Known: Sendable {
        let name: String
        let tool: String
        let relativePath: String
        var inDarwinCache = false
        let cost: DeveloperCache.Cost
        let explanation: String
        /// The tool's own cleanup, for the delegated class.
        var cleanupID: String?
        var environmentVariable: String?
        var configuredSuffix: String?
        var manualCommand: String?
        var manualReason: String?
    }

    /// Positive deletion evidence is scoped to its supplied root. Darwin's
    /// cache root is separate from home and may have a system alias above it.
    static func hasPositiveScope(_ target: URL, known: Known, home: URL, darwinCache: URL) -> Bool {
        let anchor = (known.inDarwinCache ? darwinCache : home).standardizedFileURL
        let path = target.standardizedFileURL.path
        guard anchor.path != "/", path.hasPrefix(anchor.path + "/"),
              target.resolvingSymlinksInPath().path.hasPrefix(anchor.resolvingSymlinksInPath().path + "/")
        else { return false }
        var component = anchor
        let parts = path.dropFirst(anchor.path.count + 1).split(separator: "/")
        for name in [""] + parts.map(String.init) {
            if !name.isEmpty {
                component.appendPathComponent(name)
            }
            var information = stat()
            guard lstat(component.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR else {
                return false
            }
        }
        return true
    }

    static let catalogue: [Known] = [
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
        Known(name: "Package cache", tool: "Swift",
              relativePath: "Library/Caches/org.swift.swiftpm",
              cost: .refetched,
              explanation: "Swift Package Manager's shared repository, registry download and manifest caches. "
                  + "Its cleanup removes these caches, so packages may need downloading again. "
                  + "Other cached artifacts may remain.",
              cleanupID: "swiftpm.cache"),
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
        // `cargo cache` is an add-on most people do not have, so the
        // command Brim ran for this failed. Cargo documents the registry as
        // safe to remove: the next build downloads what it needs.
        Known(name: "Registry", tool: "Cargo",
              relativePath: ".cargo/registry",
              cost: .refetched,
              explanation: "Crates Cargo has downloaded and the index it resolves against. "
                  + "Offline copies or local changes may matter. Review it with Cargo before clearing it.",
              manualReason: "Brim does not remove this shared dependency store."),
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
        // `gradle --stop` stops the build daemons and deletes nothing.
        Known(name: "Build cache", tool: "Gradle",
              relativePath: ".gradle/caches",
              cost: .refetched,
              explanation: "Dependencies and build outputs Gradle has cached. Offline dependencies may "
                  + "only exist here. Review it with Gradle after stopping builds.",
              manualReason: "Brim does not remove this mixed dependency store."),
        Known(name: "Download cache", tool: "npx",
              relativePath: ".npm/_npx",
              cost: .rebuilt,
              explanation: "Packages npx downloaded to run a command once. Downloaded again "
                  + "the next time that command runs."),
        Known(name: "Cache", tool: "uv",
              relativePath: ".cache/uv",
              cost: .refetched,
              explanation: "Packages and build artifacts shared by uv. Some environments use files here "
                  + "directly, so removing them can break those environments.",
              cleanupID: "uv.cache"),
        Known(name: "Headers", tool: "node-gyp",
              relativePath: "Library/Caches/node-gyp",
              cost: .rebuilt,
              explanation: "Node headers node-gyp downloads to build native modules. "
                  + "Downloaded again on the next native build."),
        Known(name: "IntelliSense cache", tool: "VS Code C/C++",
              relativePath: "Library/Caches/vscode-cpptools",
              cost: .rebuilt,
              explanation: "The index the C/C++ extension builds for code completion. "
                  + "Rebuilt when you next open a project."),
        Known(name: "Module cache", tool: "Clang",
              relativePath: "clang", inDarwinCache: true,
              cost: .rebuilt,
              explanation: "Compiled system and framework modules clang reuses between "
                  + "builds. Rebuilt by the next build."),
        Known(name: "Local repository", tool: "Maven",
              relativePath: ".m2/repository",
              cost: .refetched,
              explanation: "Downloaded packages and artifacts installed locally by Maven. Local packages "
                  + "may have no remote copy. Review them with Maven before clearing this store.",
              manualReason: "Locally installed artifacts may not be recoverable."),
        // These shared stores stay with their tool. Their native commands
        // can have configuration and live-project scope beyond one visible row.
        Known(name: "Package cache", tool: "Bun",
              relativePath: ".bun/install/cache", cost: .refetched,
              explanation: "Packages Bun downloaded. Clearing them needs another install and network access. "
                  + "Verify the configured cache with Bun before running its cleanup.",
              environmentVariable: "BUN_INSTALL_CACHE_DIR", manualCommand: "bun pm cache rm",
              manualReason: "Run externally after checking Bun's cache configuration."),
        Known(name: "Module cache", tool: "Deno",
              relativePath: "Library/Caches/deno", cost: .refetched,
              explanation: "Downloaded dependencies and compiled modules shared by Deno projects. "
                  + "Offline runs need these copies. Check `deno info` before cleaning.",
              environmentVariable: "DENO_DIR", manualCommand: "deno clean --dry-run",
              manualReason: "Preview externally first. Brim does not run Deno cleanup."),
        Known(name: "Global packages", tool: "NuGet",
              relativePath: ".nuget/packages", cost: .refetched,
              explanation: "Expanded packages used directly by .NET projects. Clearing them requires "
                  + "a restore and access to every package source. Check `dotnet nuget locals all --list`.",
              environmentVariable: "NUGET_PACKAGES", manualCommand: "dotnet nuget locals global-packages --clear",
              manualReason: "Run externally after checking the reported location and stopping builds."),
        Known(name: "Package cache", tool: "Yarn Classic",
              relativePath: "Library/Caches/Yarn", cost: .refetched,
              explanation: "Downloaded packages for Yarn 1. Projects may need them offline. "
                  + "Check `yarn cache dir` before clearing them with Yarn.",
              environmentVariable: "YARN_CACHE_FOLDER", manualCommand: "yarn cache clean",
              manualReason: "Run externally with the project's Yarn version and cache configuration."),
        Known(name: "Global cache", tool: "Yarn",
              relativePath: ".yarn/berry/cache", cost: .refetched,
              explanation: "Yarn's shared downloaded packages. Project-local zero-install caches can be "
                  + "part of source control and are not included in this row.",
              environmentVariable: "YARN_GLOBAL_FOLDER", configuredSuffix: "cache",
              manualReason: "Review the global cache with the project's Yarn version. Brim leaves it alone."),
        Known(name: "Build cache", tool: "Docker",
              relativePath: "Library/Containers/com.docker.docker/Data/vms",
              cost: .configured,
              explanation: "Docker's virtual machine disk, holding your images, containers "
                  + "and volumes. This is data, not a cache. Use Docker's own tools "
                  + "to prune it.")
    ]
}
