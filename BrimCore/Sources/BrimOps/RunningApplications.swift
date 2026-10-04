import AppKit
import Foundation

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
        /// No window and no Dock icon: an extension, an agent, a login item.
        public let isBackground: Bool

        public init(bundleIdentifier: String?, name: String, bundlePath: String?, isBackground: Bool = false) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.bundlePath = bundlePath
            self.isBackground = isBackground
        }
    }

    /// Everything running right now, as values, so the rest of the code
    /// can be tested without a window server.
    public static func current() -> [Running] {
        NSWorkspace.shared.runningApplications.map {
            Running(
                bundleIdentifier: $0.bundleIdentifier,
                name: $0.localizedName ?? $0.bundleURL?.lastPathComponent ?? "an application",
                bundlePath: $0.bundleURL?.resolvingSymlinksInPath().path,
                isBackground: $0.activationPolicy != .regular
            )
        }
    }

    /// Quits the app's own background parts, when nothing with a window is
    /// open, and says whether they all went.
    ///
    /// WhatsApp's notification extension was still running an hour after
    /// the app had quit, launched by macOS rather than by anybody, and the
    /// removal told the person to quit it. There is nothing to quit it
    /// from: it has no window and no Dock icon. It lives inside the bundle
    /// being removed and holds no work of the person's, so quitting it is
    /// part of the removal they asked for. It is asked first and forced
    /// only if it will not go. Anything with a window stays the person's to
    /// quit, because it may hold something unsaved.
    public static func quitBackgroundParts(bundleID: String?, bundlePath: String?) async -> Bool {
        guard partsBrimMayQuit(bundleID: bundleID, bundlePath: bundlePath) != nil else { return false }
        // The running applications themselves, matched the same way, so the
        // one asked to quit is the one that was found.
        let parts = await MainActor.run {
            NSWorkspace.shared.runningApplications.filter { app in
                app.bundleIdentifier != Bundle.main.bundleIdentifier
                    && !whatIsRunning(bundleID: bundleID, bundlePath: bundlePath, among: [
                        Running(bundleIdentifier: app.bundleIdentifier, name: "",
                                bundlePath: app.bundleURL?.resolvingSymlinksInPath().path)
                    ]).isEmpty
            }
        }
        guard !parts.isEmpty else { return true }
        await MainActor.run { parts.forEach { $0.terminate() } }
        for _ in 0 ..< 15 where await stillUp(parts) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if await stillUp(parts) {
            await MainActor.run { parts.forEach { $0.forceTerminate() } }
            for _ in 0 ..< 10 where await stillUp(parts) {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return await !stillUp(parts)
    }

    /// What Brim may quit for a removal: every running part of the app, if
    /// none of them has a window. Nil when one does, because then the
    /// person quits the app.
    public static func partsBrimMayQuit(
        bundleID: String?, bundlePath: String?, among running: [Running] = current(),
        selfBundleID: String? = Bundle.main.bundleIdentifier
    ) -> [Running]? {
        let runningParts = whatIsRunning(bundleID: bundleID, bundlePath: bundlePath, among: running)
            .filter { $0.bundleIdentifier != selfBundleID }
        return runningParts.allSatisfy(\.isBackground) ? runningParts : nil
    }

    private static func stillUp(_ parts: [NSRunningApplication]) async -> Bool {
        await MainActor.run { parts.contains { !$0.isTerminated } }
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
            // The selected path distinguishes copies sharing an identifier.
            // Fall back to identifier matching only when a path is unknown.
            if let resolvedBundle, let theirPath = candidate.bundlePath {
                let resolvedCandidate = URL(fileURLWithPath: theirPath).resolvingSymlinksInPath().path
                return resolvedCandidate == resolvedBundle || resolvedCandidate.hasPrefix(resolvedBundle + "/")
            }
            if let bundleID, let theirs = candidate.bundleIdentifier, theirs == bundleID {
                return true
            }
            return false
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
