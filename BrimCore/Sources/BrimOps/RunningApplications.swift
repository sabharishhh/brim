import AppKit
import Foundation

/// Whether the thing being removed is running. A running app keeps its
/// state in memory and writes it back when it quits, so removed files
/// reappear. A refusal, not a warning: the person quits the app and asks
/// again.
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

    /// Everything running, as values, so the rest can be tested without a
    /// window server.
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

    /// Quits the app's own background parts when nothing with a window is open,
    /// and says whether they all went. A background part has no window to quit
    /// it from and holds no unsaved work, so quitting it is part of the
    /// removal: asked first, forced only if it will not go. Anything with a
    /// window stays the person's to quit.
    public static func quitBackgroundParts(bundleID: String?, bundlePath: String?) async -> Bool {
        guard partsBrimMayQuit(bundleID: bundleID, bundlePath: bundlePath) != nil else { return false }
        // Matched the same way, so the one asked to quit is the one found.
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

    /// What Brim may quit for a removal: every running part of the app if none
    /// has a window; nil when one does.
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

    /// Whether this identity, or anything inside its bundle, is running: the
    /// identifier catches the app, the path catches helpers with their own
    /// identifiers.
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

    /// What to tell the person, or nil when nothing is in the way. Brim's own
    /// process is left out: removing Brim from Brim is supported.
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
