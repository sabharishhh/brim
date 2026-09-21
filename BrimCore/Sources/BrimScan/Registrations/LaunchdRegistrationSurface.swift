import Foundation
import BrimCore

/// Every launchd agent and daemon, in every domain, and what each points at.
///
/// T-3.2. The evidence engine already finds a plist when it can guess the
/// path from an identity; this enumerates the domains instead, which is what
/// catches a job whose plist is named after something other than its owner —
/// and a job whose program is gone entirely.
public struct LaunchdRegistrationSurface: RegistrationSurface {
    public let kind: Registration.Kind = .launchdJob

    public init() {}

    /// User, local and system domains. A job in any of them survives an
    /// uninstall that only removed the app bundle.
    private func domains(in root: FileSystemRoot) -> [(url: URL, label: String)] {
        [
            (root.url(for: .userLaunchAgents), "user"),
            (root.url(for: .systemLibrary).appendingPathComponent("LaunchAgents"), "local"),
            (root.url(for: .systemLaunchDaemons), "local"),
            (root.rootURL.appendingPathComponent("System/Library/LaunchAgents"), "system"),
            (root.rootURL.appendingPathComponent("System/Library/LaunchDaemons"), "system")
        ]
    }

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        let readable = domains(in: root).contains { FileManager.default.isReadableFile(atPath: $0.url.path) }
        return readable
            ? .available(kind)
            : .unavailable(kind, "No launchd directory could be read.", absence: .needsPermission)
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        var results: [Registration] = []
        let fm = FileManager.default

        for domain in domains(in: root) {
            let names = (try? fm.contentsOfDirectory(atPath: domain.url.path)) ?? []
            for name in names where name.hasSuffix(".plist") {
                let plistURL = domain.url.appendingPathComponent(name)
                guard let job = Self.parse(plistURL: plistURL) else { continue }

                // A job is stale when the program it launches is gone. That
                // is the entry that keeps appearing in System Settings for an
                // app the user removed months ago.
                //
                // A job that names no program at all is stale too, and was
                // being reported as healthy. Google Keystone's uninstaller
                // empties its four plists rather than deleting them, leaving
                // 181 bytes of nothing in both LaunchAgents directories.
                // launchd has no program to run and no label to register, so
                // calling those "running in the background" was wrong twice
                // over.
                let programExists: Bool
                let evidence: String
                if let program = job.program {
                    programExists = fm.fileExists(atPath: program)
                    evidence = programExists
                        ? "Registered with launchd in the \(domain.label) domain."
                        : "Registered with launchd in the \(domain.label) domain, but the program "
                          + "it launches is missing."
                } else {
                    programExists = false
                    evidence = "An empty job file in the \(domain.label) domain. It names no "
                             + "program, so launchd has nothing to run. Whatever installed it "
                             + "emptied the file instead of removing it."
                }

                results.append(Registration(
                    kind: .launchdJob,
                    identifier: job.label,
                    label: job.label,
                    owningBundleID: Self.bundleID(fromLabel: job.label),
                    programPath: job.program,
                    targetExists: programExists,
                    recordPath: plistURL.path,
                    evidence: evidence,
                    isSystemOwned: domain.label == "system",
                    // Asked of the directory, because that is what a
                    // deletion edits. /Library/LaunchAgents belongs to
                    // root, so a job there needs an administrator however
                    // ordinary its own permissions look.
                    capability: RemovalCapability.forDeleting(plistURL.path)
                ))
            }
        }
        return results
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

    static func parse(dictionary: [String: Any], fallbackLabel: String) -> Job? {
        // A plist with no label is still a job to launchd, which falls back
        // to the file name, so this does too rather than dropping it.
        let label = (dictionary["Label"] as? String) ?? fallbackLabel
        guard !label.isEmpty else { return nil }

        let program = (dictionary["Program"] as? String)
            ?? (dictionary["ProgramArguments"] as? [String])?.first

        return Job(label: label, program: program)
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
