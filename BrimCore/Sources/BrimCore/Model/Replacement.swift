import Foundation

/// An installed app that took a removed app's place.
///
/// Apps change identity: a new build ships under a new bundle identifier and
/// the old identifier's files stay behind, looking like somebody else's.
/// Saying which app replaced them turns rows that read as unknown into rows
/// a person can reason about. It is also exactly the kind of claim a cleaner
/// gets wrong by matching names, so it is made only on proof, and a missing
/// proof means nothing is said:
///
/// 1. The old identifier is not installed anywhere.
/// 2. A record says where the old app was: Brim's own snapshots, or a
///    Launch Services record for the old identifier.
/// 3. An installed app with a different identifier is at exactly that path.
/// 4. Both identifiers are in the same developer's namespace.
///
/// The same name alone proves nothing, and neither does the same developer:
/// OpenAI's current ChatGPT is `com.openai.codex`, and nothing on the Mac
/// this was written on records where `com.openai.chat` was, so its rows are
/// not claimed for it. The claim is information only. It never ticks
/// anything, and never makes a row look safer to remove.
public struct Replacement: Codable, Equatable, Hashable, Sendable {
    /// The installed app's name.
    public let name: String
    /// Where both apps were, the old one then and the new one now.
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    /// Why Brim says so, for the row's details.
    public var sentence: String {
        "\(name) is installed at \(path), where this app was, and comes from the same developer."
    }

    /// An installed application, as the matcher needs it.
    public struct Installed: Sendable, Equatable {
        public let bundleID: String
        public let name: String
        public let path: String

        public init(bundleID: String, name: String, path: String) {
            self.bundleID = bundleID
            self.name = name
            self.path = path
        }
    }

    /// The installed app that replaced `removed`, or nil when that is not
    /// proven. `formerPaths` are the places a record says the removed app
    /// was.
    public static func find(
        removed: String, formerPaths: [String], installed: [Installed]
    ) -> Replacement? {
        let old = removed.lowercased()
        guard !old.isEmpty, !old.hasPrefix("com.apple."),
              let vendor = developer(of: old),
              !installed.contains(where: { $0.bundleID.lowercased() == old })
        else { return nil }
        let places = Set(formerPaths.map(normal))
        let candidates = installed.filter { app in
            places.contains(normal(app.path))
                && app.bundleID.lowercased() != old
                && developer(of: app.bundleID) == vendor
        }
        // Two apps cannot be at one path. If the records name two places now
        // held by two different apps, there is no single answer, so none.
        guard candidates.count == 1, let app = candidates.first else { return nil }
        return Replacement(name: app.name, path: app.path)
    }

    /// The developer's part of a reverse-DNS identifier: `com.openai` for
    /// `com.openai.chat`, `co.uk` style domains one deeper, and on shared
    /// hosts such as `com.github` the account as well, since two people's
    /// projects there are not one developer's. Nil unless something is left
    /// after it to name a product.
    static func developer(of identifier: String) -> String? {
        let parts = identifier.lowercased().split(separator: ".").map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        var depth = 2
        if parts.count >= 2, parts[0].count == 2, ["co", "com", "ac", "or", "ne", "org", "net"].contains(parts[1]) {
            depth = 3
        }
        let shared: Set = ["com.github", "io.github", "com.gitlab", "io.gitlab", "com.googlecode",
                           "org.sourceforge", "net.sourceforge", "com.bitbucket", "com.herokuapp"]
        if parts.count >= 2, shared.contains(parts[0] + "." + parts[1]) {
            depth = 3
        }
        guard parts.count > depth else { return nil }
        return parts.prefix(depth).joined(separator: ".")
    }

    /// Paths compare as the file system does here: the same file however
    /// it is spelled, and without regard to case.
    static func normal(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        while url.count > 1, url.hasSuffix("/") { url.removeLast() }
        return url.lowercased()
    }
}
