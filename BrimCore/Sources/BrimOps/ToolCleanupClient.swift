import BrimCore
import CryptoKit
import Foundation

public extension ToolCleanup {
    /// Local dependencies, installed by Brim rather than supplied by a caller.
    struct Client: Sendable {
        private let environmentSource: @Sendable () -> [String: String]
        private let query: @Sendable (String, [String], [String: String], String) async throws -> String
        private let invoke: @Sendable (ToolCleanupBinding, [String: String]) async throws -> Void

        public init() {
            environmentSource = ToolCleanup.environment
            query = Self.queryTool
            invoke = Self.invokeTool
        }

        init(environment: @escaping @Sendable () -> [String: String]) {
            environmentSource = environment
            query = Self.queryTool
            invoke = Self.invokeTool
        }

        /// Tests use harmless fixture tools and record the approved invocation.
        init(
            environment: @escaping @Sendable () -> [String: String],
            query: @escaping @Sendable (String, [String], [String: String], String) async throws -> String,
            invoke: @escaping @Sendable (ToolCleanupBinding, [String: String]) async throws -> Void
        ) {
            environmentSource = environment
            self.query = query
            self.invoke = invoke
        }

        public func request(id: String, cachePath: URL? = nil) throws -> ToolCleanupRequest {
            guard let known = ToolCleanupRequest.CleanupID(rawValue: id) else {
                throw CleanupError.unknownCleanup(id)
            }
            let environment = currentEnvironment()
            guard let home = environment["HOME"], home.hasPrefix("/") else {
                throw CleanupError.configurationUnavailable("The home folder could not be resolved.")
            }
            return ToolCleanupRequest(id: known, cachePath: cachePath ?? Self.rowPath(known, home: home))
        }

        @concurrent
        public func prepare(_ request: ToolCleanupRequest) async throws -> ToolCleanupBinding {
            guard let command = ToolCleanup.command(id: request.id.rawValue) else {
                throw CleanupError.unknownCleanup(request.id.rawValue)
            }
            if let reason = command.manualReason {
                throw CleanupError.manualOnly(reason)
            }
            let environment = currentEnvironment()
            guard let home = environment["HOME"], home.hasPrefix("/") else {
                throw CleanupError.configurationUnavailable("The home folder could not be resolved.")
            }
            let row = Self.rowPath(request.id, home: home)
            guard request.cachePath.standardizedFileURL == row.standardizedFileURL else {
                throw CleanupError.configurationUnavailable("The requested row is not a registered cache location.")
            }
            if request.id == .swiftPM {
                return try await prepareSwiftPM(request, row: row, environment: environment, home: home)
            }
            let names = request.id == .pip ? ["pip", "pip3"] : [request.id == .npm ? "npm" : "go"]
            let executable = try Self.resolve(names, environment: environment, displayed: command.displayed)
            let probe = Self.probe(request.id)
            let reported = try await query(executable, probe, environment, home)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard reported.hasPrefix("/"), !reported.contains("\n"), !reported.contains("\0") else {
                throw CleanupError.configurationUnavailable("The tool did not report one absolute cache path.")
            }
            let scope = URL(fileURLWithPath: reported).resolvingSymlinksInPath().standardizedFileURL
            let expected = (request.id == .npm ? row.deletingLastPathComponent() : row)
                .resolvingSymlinksInPath().standardizedFileURL
            guard scope == expected else {
                throw CleanupError.scopeChanged(command.displayed, actual: scope.path)
            }
            let homePath = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
            guard scope.path.hasPrefix(homePath + "/") else {
                throw CleanupError.configurationUnavailable(
                    "This cache is outside the home folder. Review it in the tool."
                )
            }
            return try Self.binding(request, executable: executable, scope: scope, environment: environment, home: home)
        }

        private static func binding(
            _ request: ToolCleanupRequest,
            executable: String,
            scope: URL,
            environment: [String: String],
            home: String
        ) throws -> ToolCleanupBinding {
            let scopeStat = try Self.readStat(scope.path)
            guard scopeStat.st_mode & S_IFMT == S_IFDIR else {
                throw CleanupError.configurationUnavailable("The cache location is no longer a folder.")
            }
            let executableStat = try Self.readStat(executable)
            guard executableStat.st_size <= 100 * 1024 * 1024 else {
                throw CleanupError.configurationUnavailable(
                    "The tool is too large to verify within the cleanup budget."
                )
            }
            let modified = Double(executableStat.st_mtimespec.tv_sec)
                + Double(executableStat.st_mtimespec.tv_nsec) / 1_000_000_000
            let fingerprint = TargetFingerprint(
                dev: executableStat.st_dev,
                ino: executableStat.st_ino,
                mtime: Date(timeIntervalSince1970: modified)
            )
            let executableHash = try Self.hash(Data(contentsOf: URL(fileURLWithPath: executable)))
            let arguments = Self.arguments(request.id, scope: scope.path)
            let executionEnvironment = Self.pinnedEnvironment(environment, id: request.id, scope: scope.path)
            let environmentHash = try Self.environmentHash(executionEnvironment)
            let words = ([executable] + arguments).map(Self.quoted).joined(separator: " ")
            let displayed = request.id == .goModules ? "GOMODCACHE=\(Self.quoted(scope.path)) " + words : words
            return ToolCleanupBinding(
                id: request.id,
                catalogueRevision: request.id == .swiftPM ? "swiftpm-1" : "1",
                executable: executable,
                executableFingerprint: fingerprint,
                executableHash: executableHash,
                scope: scope.path,
                scopeDevice: scopeStat.st_dev,
                scopeInode: scopeStat.st_ino,
                arguments: arguments,
                environmentHash: environmentHash,
                workingDirectory: home,
                displayed: displayed
            )
        }

        public func run(_ approved: ToolCleanupBinding, request: ToolCleanupRequest) async throws {
            // Rebuild at the mutation boundary too. Stored argv is never dispatched.
            let current = try await prepare(request)
            guard current == approved else { throw CleanupError.bindingChanged }
            let environment = Self.pinnedEnvironment(currentEnvironment(), id: current.id, scope: current.scope)
            let environmentHash = try Self.environmentHash(environment)
            guard environmentHash == current.environmentHash else { throw CleanupError.bindingChanged }
            try await invoke(current, environment)
        }

        private func currentEnvironment() -> [String: String] {
            // No loader overrides, project hooks or unrelated secrets enter the tool.
            let permitted = Set([
                "HOME",
                "USER",
                "LOGNAME",
                "TMPDIR",
                "PATH",
                "LANG",
                "LC_CTYPE",
                "XDG_CACHE_HOME",
                "XDG_CONFIG_HOME",
                "GOPATH",
                "GOENV",
                "GOMODCACHE",
                "GOCACHE",
                "npm_config_cache",
                "npm_config_userconfig",
                "npm_config_globalconfig",
                "NPM_CONFIG_CACHE",
                "NPM_CONFIG_USERCONFIG",
                "NPM_CONFIG_GLOBALCONFIG",
                "PIP_CACHE_DIR",
                "PIP_CONFIG_FILE"
            ])
            var environment = environmentSource().filter { permitted.contains($0.key) }
            environment["GOTOOLCHAIN"] = "local"
            return environment
        }

        private static func rowPath(_ id: ToolCleanupRequest.CleanupID, home: String) -> URL {
            let path = switch id {
            case .npm: ".npm/_cacache"
            case .goModules: "go/pkg/mod"
            case .pip: "Library/Caches/pip"
            case .homebrew: "Library/Caches/Homebrew"
            case .pnpm: "Library/pnpm/store"
            case .uvCache: ".cache/uv"
            case .simulators: "Library/Developer/CoreSimulator/Devices"
            case .swiftPM: "Library/Caches/org.swift.swiftpm"
            }
            return URL(fileURLWithPath: home).appendingPathComponent(path)
        }

        private static func probe(_ id: ToolCleanupRequest.CleanupID) -> [String] {
            switch id {
            case .npm: ["config", "get", "cache"]
            case .goModules: ["env", "GOMODCACHE"]
            case .pip: ["cache", "dir"]
            default: [] // Refused before probing.
            }
        }

        private static func arguments(_ id: ToolCleanupRequest.CleanupID, scope: String) -> [String] {
            switch id {
            case .npm: ["--cache", scope, "cache", "clean", "--force"]
            case .goModules: ["clean", "-modcache"]
            case .pip: ["--cache-dir", scope, "cache", "purge"]
            case .swiftPM: [
                    "--cache-path",
                    scope,
                    "--scratch-path",
                    scope,
                    "--config-path",
                    scope,
                    "--security-path",
                    scope,
                    "--swift-sdks-path",
                    scope,
                    "purge-cache"
                ]
            default: []
            }
        }

        private static func pinnedEnvironment(
            _ environment: [String: String],
            id: ToolCleanupRequest.CleanupID,
            scope: String
        ) -> [String: String] {
            var result = environment
            if id == .goModules {
                result["GOMODCACHE"] = scope
            }
            return result
        }

        private static func resolve(
            _ names: [String],
            environment: [String: String],
            displayed: String
        ) throws -> String {
            for name in names {
                for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
                    let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
                        .resolvingSymlinksInPath().standardizedFileURL
                    var information = stat()
                    guard stat(url.path, &information) == 0 else { continue }
                    guard information.st_mode & S_IFMT == S_IFREG, access(url.path, X_OK) == 0 else { continue }
                    return url.path
                }
            }
            throw CleanupError.toolMissing(displayed)
        }

        private static func environmentHash(_ environment: [String: String]) throws -> String {
            let data = try JSONEncoder().encode(environment.sorted { $0.key < $1.key }.map { [$0.key, $0.value] })
            return hash(data)
        }

        private static func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private static func quoted(_ word: String) -> String {
            "'" + word.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
    }
}

private extension ToolCleanup.Client {
    func prepareSwiftPM(
        _ request: ToolCleanupRequest, row: URL, environment: [String: String], home: String
    ) async throws -> ToolCleanupBinding {
        let originalCache = try Self.swiftPMCacheInformation(home: home)
        // Bind the actual SwiftPM binary, rather than Apple's tool-selection shim.
        let selected = try await query("/usr/bin/xcrun", ["--find", "swift-package"], environment, home)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected.hasPrefix("/"), !selected.contains("\n"), !selected.contains("\0") else {
            throw ToolCleanup.CleanupError.configurationUnavailable("Xcode did not report one Swift package tool.")
        }
        let executable = URL(fileURLWithPath: selected).resolvingSymlinksInPath().standardizedFileURL.path
        let information = try Self.readStat(executable)
        guard information.st_mode & S_IFMT == S_IFREG, access(executable, X_OK) == 0 else {
            throw ToolCleanup.CleanupError.toolMissing("swift package purge-cache")
        }
        let version = try await query(executable, ["--version"], environment, home)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.hasPrefix("Swift Package Manager - Swift 6.4.") else {
            throw ToolCleanup.CleanupError.configurationUnavailable(
                "This Swift package tool has not been verified for scoped cache cleanup. Manage the cache in Xcode."
            )
        }
        let currentCache = try Self.swiftPMCacheInformation(home: home)
        guard currentCache.st_dev == originalCache.st_dev, currentCache.st_ino == originalCache.st_ino else {
            throw ToolCleanup.CleanupError.bindingChanged
        }
        let scope = row.resolvingSymlinksInPath().standardizedFileURL
        let homePath = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        guard scope.path.hasPrefix(homePath + "/") else {
            throw ToolCleanup.CleanupError.configurationUnavailable("This package cache is outside the home folder.")
        }
        try Self.checkSwiftPMPaths(scope)
        return try Self.binding(request, executable: executable, scope: scope, environment: environment, home: home)
    }

    static func swiftPMCacheInformation(home: String) throws -> stat {
        var component = URL(fileURLWithPath: home)
        var information = stat()
        for name in ["Library", "Caches", "org.swift.swiftpm"] {
            component.appendPathComponent(name)
            information = try Self.readStat(component.path)
            guard information.st_mode & S_IFMT == S_IFDIR else {
                throw ToolCleanup.CleanupError.configurationUnavailable(
                    "A package cache path is a link or is no longer a folder. Manage this cache in Xcode."
                )
            }
        }
        return information
    }

    static func readStat(_ path: String) throws -> stat {
        var information = stat()
        guard lstat(path, &information) == 0 else {
            throw ToolCleanup.CleanupError
                .configurationUnavailable("Could not inspect \(path). Review the cache again.")
        }
        return information
    }

    static func queryTool(
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ home: String
    ) async throws -> String {
        let result = try await NativeCommandRunner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: 10,
            workingDirectory: home
        )
        guard result.termination == .exited(0), !result.outputTruncated,
              let text = String(data: result.stdout, encoding: .utf8)
        else {
            throw ToolCleanup.CleanupError.configurationUnavailable(
                "Could not read the tool's cache configuration. Nothing was cleaned."
            )
        }
        return text
    }

    static func invokeTool(_ binding: ToolCleanupBinding, _ environment: [String: String]) async throws {
        let result: NativeCommandRunner.Result
        do {
            result = try await NativeCommandRunner.run(
                executable: binding.executable,
                arguments: binding.arguments,
                environment: environment,
                workingDirectory: binding.workingDirectory
            )
        } catch let failure as NativeCommandRunner.Failure {
            throw ToolCleanup.mapped(failure, displayed: binding.displayed)
        }
        switch result.termination {
        case .exited(0): return
        case let .exited(code): throw ToolCleanup.CleanupError.failed(binding.displayed, code: code)
        case let .signalled(signal): throw ToolCleanup.CleanupError.signalled(binding.displayed, signal: signal)
        case .timedOut: throw ToolCleanup.CleanupError.timedOut(binding.displayed)
        case .cancelled: throw ToolCleanup.CleanupError.cancelled(binding.displayed)
        }
    }
}

extension ToolCleanup.Client {
    /// A stopped check cannot authorize the native command. The entry budget
    /// covers all four shallow surfaces, not each directory independently.
    static func checkSwiftPMPaths(
        _ scope: URL, budget: ScanBudget = ScanBudget(total: 10), maximumEntries: Int = 20000
    ) throws {
        var check = SwiftPMCacheCheck(budget: budget, maximumEntries: max(0, maximumEntries))
        try check.validate(scope)
    }
}
