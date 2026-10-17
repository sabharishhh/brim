import BrimCore
import Foundation

/// Root-owned helper binaries in `/Library/PrivilegedHelperTools`, and the
/// daemons that start them. Neither is inside the app bundle, so removing
/// the app leaves a root binary nothing updates. Reported as one row per
/// helper and daemon pair.
public struct PrivilegedHelperToolSurface: RegistrationSurface {
    public let kind: Registration.Kind = .privilegedHelper

    public init() {}

    private func directory(in root: FileSystemRoot) -> URL {
        root.rootURL.appendingPathComponent("Library/PrivilegedHelperTools")
    }

    private func daemons(in root: FileSystemRoot) -> URL {
        root.rootURL.appendingPathComponent("Library/LaunchDaemons")
    }

    public func coverage(in root: FileSystemRoot) async -> RegistrationCoverage {
        let path = directory(in: root).path
        let fm = FileManager.default
        // Absent is a complete answer: a Mac where nothing needed administrator
        // rights has no such folder.
        guard fm.fileExists(atPath: path) else { return .available(kind) }
        return fm.isReadableFile(atPath: path)
            ? .available(kind)
            : .unavailable(kind, "The privileged helper folder could not be read.", absence: .needsPermission)
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        await snapshot(in: root).registrations
    }

    public func snapshot(in root: FileSystemRoot) async -> RegistrationSnapshot {
        let fm = FileManager.default
        let folder = directory(in: root)
        let names: [String]
        switch DirectoryEntries.read(folder) {
        case .absent: names = []
        case let .listed(entries): names = entries
        case .refused:
            return RegistrationSnapshot(registrations: [], coverage: .unavailable(
                kind, "The privileged helper folder could not be read."
            ))
        }
        let found = names.sorted().compactMap { name -> Registration? in
            guard !name.hasPrefix(".") else { return nil }
            let tool = folder.appendingPathComponent(name)

            // The helper's file name is its launchd label, as `SMJobBless` requires.
            let daemonPlist = daemons(in: root).appendingPathComponent("\(name).plist")
            let hasDaemon = fm.fileExists(atPath: daemonPlist.path)

            // A helper is signed by the team that shipped the app, the only honest
            // link back once the app is gone.
            let signing = CodeSignature.state(of: tool, recordedTeam: nil)
            let owner = Self.probableOwner(label: name)

            let evidence = if hasDaemon {
                "Runs as an administrator, started by a launchd daemon of the same name."
            } else {
                "Runs as an administrator, with no launchd daemon left to start it."
            }

            return Registration(
                kind: .privilegedHelper,
                identifier: name,
                label: name,
                owningBundleID: owner,
                programPath: tool.path,
                // Whether its app is still here is the uninstall's question, through
                // `belongs`.
                targetExists: true,
                recordPath: hasDaemon ? daemonPlist.path : tool.path,
                evidence: evidence,
                isSystemOwned: name.hasPrefix("com.apple."),
                signing: signing,
                capability: RemovalCapability.forDeleting(tool.path),
                targetPresence: PathObservation.observe(tool.path)
            )
        }
        return RegistrationSnapshot(registrations: found, coverage: .available(kind))
    }

    /// The bundle identifier a helper's label implies. Used for grouping only;
    /// removal goes through the signing team and the path.
    static func probableOwner(label: String) -> String? {
        let parts = label.split(separator: ".")
        guard parts.count > 3 else { return label.isEmpty ? nil : label }
        return parts.dropLast().joined(separator: ".")
    }
}
