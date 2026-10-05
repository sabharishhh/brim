import AppKit
import BrimCore
import BrimPrivileged
import os

private let log = Logger(subsystem: "com.sabharishhh.brim", category: "self-removal")

/// Removes Brim and everything it wrote, leaving nothing behind and nothing
/// in the Trash.
///
/// What only root can clear goes first, through the temporary administrator
/// process, while the bundle is still there for `tccutil` to find. Then a
/// script waits for Brim to quit and deletes the rest, so nothing Brim does
/// on its way out can write a file back.
@MainActor
enum SelfRemoval {
    static let confirmationTitle = "Remove Brim completely?"
    static let confirmationMessage = "Brim, its history, saved icons and settings are deleted "
        + "permanently. Nothing goes to the Trash. Items Brim moved to the Trash stay there, "
        + "but can no longer be put back with Brim. macOS may ask for an administrator password."

    /// Returns why Brim could not remove itself, or quits.
    static func perform(helper: PrivilegedHelperClient) async -> String? {
        if let problem = await helper.uninstall(resettingPrivacy: FullDiskAccessProbe.isGranted()) {
            log.error("could not clear what root owns: \(problem)")
            return "Brim's folder in /Library could not be cleared, so nothing has been removed.\n\n"
                + problem
        }
        let bundle = Bundle.main.bundleURL
        let identifiers = [Bundle.main.bundleIdentifier ?? BrimJobHelper.applicationIdentifier,
                           BrimJobHelper.applicationIdentifier + ".jobhelper"]
            + SafetyChecker.identifiersOlderBuildsUsed.sorted()
        // Grants in the person's own privacy database, while the bundle is
        // still there to be found by.
        run("/usr/bin/tccutil", ["reset", "All", identifiers[0]])
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        var paths = BrimTraces.paths(in: root, identifiers: identifiers)
        if bundle.pathExtension == "app" {
            paths.insert(bundle, at: 0)
        }
        let script = BrimTraces.removalScript(
            paths: paths, preferenceDomains: identifiers,
            unregistering: bundle.pathExtension == "app" ? bundle : nil
        )
        let file = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("brim-removal-\(UUID().uuidString).sh")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [file.path]
            // Held until Brim's process ends; the script starts when it closes.
            let lifeline = Pipe()
            process.standardInput = lifeline
            try process.run()
            Self.lifeline = lifeline
        } catch {
            log.error("could not start the removal: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: file)
            return "Brim could not start removing itself. \(error.localizedDescription)"
        }
        NSApplication.shared.terminate(nil)
        return nil
    }

    private static var lifeline: Pipe?

    private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
