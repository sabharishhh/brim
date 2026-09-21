import Foundation
import BrimCore

/// Root-owned helper binaries, and the daemons that start them.
///
/// An application that ever needed administrator rights installs a binary
/// in `/Library/PrivilegedHelperTools` and a LaunchDaemon to run it. Both
/// are owned by root and neither is inside the application bundle, so
/// dragging the app to the Trash leaves a root binary installed for
/// software that no longer exists. It is the worst leftover in the
/// catalogue: it runs as root, nothing updates it any more, and the
/// person has no idea it is there.
///
/// The two halves are reported as one row. A helper without its daemon is
/// inert, a daemon without its helper is already covered by the launchd
/// surface, and a person thinks about "the thing Foo installed", not
/// about which of the two files it is.
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
        // Absent is a complete answer: a Mac where nothing ever asked for
        // administrator rights has no such folder.
        guard fm.fileExists(atPath: path) else { return .available(kind) }
        return fm.isReadableFile(atPath: path)
            ? .available(kind)
            : .unavailable(kind, "The privileged helper folder could not be read.")
    }

    public func registrations(in root: FileSystemRoot) async -> [Registration] {
        let fm = FileManager.default
        let folder = directory(in: root)
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }

        return names.sorted().compactMap { name -> Registration? in
            guard !name.hasPrefix(".") else { return nil }
            let tool = folder.appendingPathComponent(name)

            // The helper's file name is its launchd label, by convention
            // and by SMJobBless's requirement.
            let daemonPlist = daemons(in: root).appendingPathComponent("\(name).plist")
            let hasDaemon = fm.fileExists(atPath: daemonPlist.path)

            // Whose it is. A helper is signed by the team that shipped the
            // application, which is the only honest link back when the
            // application itself is gone.
            let signing = CodeSignature.state(of: tool, recordedTeam: nil)
            let owner = Self.probableOwner(label: name)

            let evidence: String
            if hasDaemon {
                evidence = "A helper that runs as an administrator, started by a launchd "
                         + "daemon of the same name. It was installed by an application "
                         + "asking for administrator rights."
            } else {
                evidence = "A helper that runs as an administrator, with no launchd daemon "
                         + "left to start it. Nothing runs it now, and nothing updates it."
            }

            return Registration(
                kind: .privilegedHelper,
                identifier: name,
                label: name,
                owningBundleID: owner,
                programPath: tool.path,
                // The binary is here. Whether its application still is, is
                // what the uninstall decides through `belongs`.
                targetExists: true,
                recordPath: hasDaemon ? daemonPlist.path : tool.path,
                evidence: evidence,
                isSystemOwned: name.hasPrefix("com.apple."),
                signing: signing,
                capability: RemovalCapability.forDeleting(tool.path)
            )
        }
    }

    /// The bundle identifier a helper's label implies.
    ///
    /// `SMJobBless` requires the label to be the helper's own bundle
    /// identifier, which vendors almost always derive from the
    /// application's. Used for grouping rows, never for deciding a
    /// removal: that goes through the signing team and the path, the same
    /// way every other ownership question does.
    static func probableOwner(label: String) -> String? {
        let parts = label.split(separator: ".")
        guard parts.count > 3 else { return label.isEmpty ? nil : label }
        return parts.dropLast().joined(separator: ".")
    }
}
