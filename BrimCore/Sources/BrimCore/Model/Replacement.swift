import Foundation

/// An installed app that took a removed app's place, said only on proof:
/// 1. The old identifier is not installed anywhere.
/// 2. A record says where the old app was: Brim's snapshots, or a Launch
///    Services record for the old identifier.
/// 3. An installed app with a different identifier is at exactly that path.
/// 4. Both identifiers are in the same developer's namespace.
/// The same name, or the same developer elsewhere, proves nothing. The claim
/// is information only: it never ticks anything or makes a row look safer.
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
    /// proven. `formerPaths` are where a record says the removed app was.
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
        // Records naming two places now held by two different apps give no single
        // answer, so none.
        guard candidates.count == 1, let app = candidates.first else { return nil }
        return Replacement(name: app.name, path: app.path)
    }

    /// The developer's part of a reverse-DNS identifier: `com.openai` for
    /// `com.openai.chat`, one deeper for `co.uk`-style domains, and on shared
    /// hosts such as `com.github` the account too. Nil unless a product label
    /// follows.
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
        while url.count > 1, url.hasSuffix("/") {
            url.removeLast()
        }
        return url.lowercased()
    }
}
