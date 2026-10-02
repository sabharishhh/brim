import BrimCore
import Foundation

/// Every launchd agent and daemon, in every domain, and what each points at.
///
/// T-3.2. The evidence engine already finds a plist when it can guess the
/// path from an identity; this enumerates the domains instead, which is what
/// catches a job whose plist is named after something other than its owner —
/// and a job whose program is gone entirely.
public struct LaunchdRegistrationSurface: RegistrationSurface {
    public let kind: Registration.Kind = .launchdJob

    private let includeSystemJobs: Bool

    public init(includeSystemJobs: Bool = true) {
        self.includeSystemJobs = includeSystemJobs
    }

    /// User, local and system domains. A job in any of them survives an
    /// uninstall that only removed the app bundle.
    private func domains(in root: FileSystemRoot) -> [(url: URL, label: String)] {
        let applicationDomains: [(url: URL, label: String)] = [
            (root.url(for: .userLaunchAgents), "user"),
            (root.url(for: .systemLibrary).appendingPathComponent("LaunchAgents"), "local"),
            (root.url(for: .systemLaunchDaemons), "local")
        ]
        // Protected OS folders also contain configuration plists that are
        // not job declarations. They are outside an application's removal
        // scope and must not invalidate an application-job inventory.
        guard includeSystemJobs else { return applicationDomains }
        return applicationDomains + [
            (root.rootURL.appendingPathComponent("System/Library/LaunchAgents"), "system"),
            (root.rootURL.appendingPathComponent("System/Library/LaunchDaemons"), "system")
        ]
    }

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        await snapshot(in: root).coverage
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        await snapshot(in: root).registrations
    }

    public func snapshot(in root: FileSystemRoot) async -> RegistrationSnapshot {
        var results: [Registration] = []
        var scopes: [RegistrationCoverage.Scope] = []
        for directory in domains(in: root) {
            var complete = true
            let names: [String]
            switch DirectoryEntries.read(directory.url) {
            case .absent: names = []
            case let .listed(entries): names = entries
            case .refused:
                names = []
                complete = false
            }
            for name in names where name.hasSuffix(".plist") {
                let plist = directory.url.appendingPathComponent(name)
                guard let definition = try? LaunchdJobDefinition.read(plist.path) else {
                    complete = false
                    continue
                }
                let program = definition.resolvedProgram(plistPath: plist.path)
                let presence = PathObservation.observe(program, followingLinks: true)
                let namespace = directory.url.path.contains("/LaunchDaemons")
                    ? "system" : "gui/\(getuid())"
                results.append(Registration(
                    kind: .launchdJob, identifier: definition.label, label: definition.label,
                    owningBundleID: Self.bundleID(fromLabel: definition.label),
                    programPath: program, targetExists: presence.isPresent,
                    recordPath: plist.path,
                    evidence: presence.isAbsent
                        ? "The launchd declaration remains, but its program is missing."
                        : "A launchd job declaration in \(directory.url.path).",
                    isSystemOwned: directory.label == "system",
                    capability: RemovalCapability.forDeleting(plist.path),
                    targetPresence: presence, namespace: namespace, runtimeState: "declared"
                ))
            }
            scopes.append(.init(namespace: directory.url.path, available: complete,
                                limitation: complete ? nil : "A job folder or declaration could not be read."))
        }
        let complete = scopes.allSatisfy(\.available)
        return RegistrationSnapshot(registrations: results, coverage: RegistrationCoverage(
            kind: kind, available: complete,
            limitation: complete ? nil : "Part of the background job list could not be checked.",
            scopes: scopes
        ), readerVersion: 2)
    }

    // MARK: - Parsing

    struct Job: Equatable {
        let label: String
        /// The executable, from `Program` or the first `ProgramArguments` entry.
        let program: String?
    }

    /// Reads a job's label and program without executing anything.
    static func parse(plistURL: URL) -> Job? {
        guard let data = try? Data(contentsOf: plistURL),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = raw as? [String: Any]
        else { return nil }
        return parse(dictionary: dict, fallbackLabel: plistURL.deletingPathExtension().lastPathComponent)
    }

    static func parse(dictionary: [String: Any], fallbackLabel _: String) -> Job? {
        guard let definition = LaunchdJobDefinition(dictionary: dictionary) else { return nil }
        return Job(label: definition.label, program: definition.program)
    }

    /// launchd labels are conventionally the bundle identifier, sometimes with
    /// a suffix. Only an exact reverse-DNS prefix is treated as ownership —
    /// a substring match would attribute `com.foo.bar` to `com.foo`.
    static func bundleID(fromLabel label: String) -> String? {
        let parts = label.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return label
    }
}
