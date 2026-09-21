import Foundation
import AppKit

/// Whether the thing being removed is running right now.
///
/// Removing a running application does not stop it. The process keeps its
/// file descriptors, keeps its state in memory, and writes it back out
/// when it quits, so the preferences and caches Brim just removed reappear
/// minutes later and the removal looks like it silently failed. Worse,
/// the application is usually still in the Dock and still launchable from
/// a Trash it has been moved into.
///
/// So this is a refusal, not a warning to click past. The person quits the
/// app and asks again, which takes five seconds and works.
public enum RunningApplications {

    public struct Running: Equatable, Sendable {
        public let bundleIdentifier: String?
        public let name: String
        public let bundlePath: String?

        public init(bundleIdentifier: String?, name: String, bundlePath: String?) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.bundlePath = bundlePath
        }
    }

    /// Everything running right now, as values, so the rest of the code
    /// can be tested without a window server.
    public static func current() -> [Running] {
        NSWorkspace.shared.runningApplications.map {
            Running(
                bundleIdentifier: $0.bundleIdentifier,
                name: $0.localizedName ?? $0.bundleURL?.lastPathComponent ?? "an application",
                bundlePath: $0.bundleURL?.resolvingSymlinksInPath().path
            )
        }
    }

    /// Whether this identity, or anything living inside its bundle, is up.
    ///
    /// Matched two ways on purpose. The bundle identifier catches the
    /// application itself. The path catches its helpers: a login item at
    /// `App.app/Contents/Library/LoginItems/Helper.app` has its own
    /// identifier and is just as capable of rewriting what Brim removes.
    public static func whatIsRunning(
        bundleID: String?,
        bundlePath: String?,
        among running: [Running] = current()
    ) -> [Running] {
        let resolvedBundle = bundlePath.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }

        return running.filter { candidate in
            if let bundleID, let theirs = candidate.bundleIdentifier, theirs == bundleID {
                return true
            }
            guard let resolvedBundle, let theirPath = candidate.bundlePath else { return false }
            return theirPath == resolvedBundle
                || theirPath.hasPrefix(resolvedBundle.hasSuffix("/") ? resolvedBundle : resolvedBundle + "/")
        }
    }

    /// What to tell the person, or nil when nothing is in the way.
    ///
    /// Brim's own process is left out. Uninstalling Brim from inside Brim
    /// is a supported thing to do, and the app quits itself once the plan
    /// has run.
    public static func refusal(
        bundleID: String?,
        bundlePath: String?,
        among running: [Running] = current(),
        selfBundleID: String? = Bundle.main.bundleIdentifier
    ) -> String? {
        let blocking = whatIsRunning(bundleID: bundleID, bundlePath: bundlePath, among: running)
            .filter { $0.bundleIdentifier != selfBundleID }
        guard !blocking.isEmpty else { return nil }

        let names = Array(Set(blocking.map(\.name))).sorted()
        if names.count == 1 {
            return "\(names[0]) is running. Quit it first: an application that is still open "
                 + "writes its settings back out when it closes, so removing them now would "
                 + "undo itself a few minutes from now."
        }
        let list = names.count <= 3
            ? names.joined(separator: ", ")
            : "\(names.prefix(3).joined(separator: ", ")) and \(names.count - 3) more"
        return "These are running: \(list). Quit them first, or what they write out when "
             + "they close will undo the removal."
    }
}
