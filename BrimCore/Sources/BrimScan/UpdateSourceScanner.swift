import Foundation
import BrimCore

/// Works out how each application updates, entirely from the disk.
///
/// No network, on purpose and by specification. Every answer is a file:
/// `SUFeedURL` in an `Info.plist`, a receipt inside the bundle, a
/// directory in Homebrew's Caskroom. The view renders identically with
/// the network off, and `UpdateSourceTests` fails if a URL request
/// appears in this file.
///
/// Fetching a feed to see whether a newer version exists is a separate
/// act, on an explicit press, and is not this.
public struct UpdateSourceScanner: Sendable {

    private let homebrewPrefixes: [String]

    public init(
        homebrewPrefixes: [String] = ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"]
    ) {
        self.homebrewPrefixes = homebrewPrefixes
    }

    /// Every cask Homebrew has installed, by its directory name.
    ///
    /// Read from the Caskroom rather than by running `brew list`, which
    /// takes seconds and needs Homebrew's Ruby to start. The directory is
    /// the same answer and costs one listing.
    public func installedCasks(fileManager: FileManager = .default) -> Set<String> {
        var casks: Set<String> = []
        for prefix in homebrewPrefixes {
            let caskroom = "\(prefix)/Caskroom"
            guard let names = try? fileManager.contentsOfDirectory(atPath: caskroom) else {
                continue
            }
            casks.formUnion(names.filter { !$0.hasPrefix(".") })
        }
        return casks
    }

    public func homebrewIsInstalled(fileManager: FileManager = .default) -> Bool {
        homebrewPrefixes.contains {
            fileManager.fileExists(atPath: "\($0)/Caskroom")
                || fileManager.fileExists(atPath: "\($0)/bin/brew")
        }
    }

    /// Everything Brim can tell about one application, from files alone.
    public func sources(
        for application: InstalledApplication,
        casks: Set<String>,
        fileManager: FileManager = .default
    ) -> [UpdateSource] {
        var found: [UpdateSource] = []
        let bundle = application.url

        // An App Store receipt is a file inside the bundle. Its presence
        // is the purchase, which is why it is the one signal that cannot
        // be faked by a plist key.
        if fileManager.fileExists(atPath: bundle.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
            found.append(.appStore)
        }

        if let feed = Self.sparkleFeed(at: bundle) {
            found.append(.sparkle(feed: feed))
        }

        if let cask = Self.matchingCask(for: application, among: casks) {
            found.append(.homebrewCask(name: cask))
        }

        return found
    }

    /// The Sparkle feed a bundle declares, if it declares one.
    ///
    /// `SUFeedURL` is the standard key. A bundle that ships Sparkle and
    /// sets the feed at runtime instead will not be found here, and that
    /// is the right failure: Brim reports what it can prove, and a
    /// framework being present is not a promise that anything checks.
    public static func sparkleFeed(at bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }

        if let feed = parsed["SUFeedURL"] as? String, !feed.isEmpty { return feed }
        // Some bundles carry it per-channel under a dictionary.
        if let feeds = parsed["SUFeedURLs"] as? [String: String],
           let first = feeds.values.sorted().first, !first.isEmpty {
            return first
        }
        return nil
    }

    /// Which cask installed this application, if one did.
    ///
    /// Homebrew names a cask after the software, not after the bundle, so
    /// `boringNotch.app` comes from `boring-notch`. Matched by
    /// normalising both sides rather than by reading each cask's metadata,
    /// which would mean parsing Ruby.
    ///
    /// Deliberately strict. A loose match here would tell somebody to run
    /// `brew uninstall` on a cask that installed something else.
    public static func matchingCask(
        for application: InstalledApplication, among casks: Set<String>
    ) -> String? {
        let candidates = [
            application.name,
            application.url.deletingPathExtension().lastPathComponent,
            application.identity.bundleID?.split(separator: ".").last.map(String.init) ?? "",
        ]
        for candidate in candidates where !candidate.isEmpty {
            let normalised = normalise(candidate)
            guard !normalised.isEmpty else { continue }
            if let hit = casks.first(where: { normalise($0) == normalised }) {
                return hit
            }
        }
        return nil
    }

    /// Lowercased, with everything that is not a letter or a number
    /// removed, so "boringNotch" and "boring-notch" are the same word and
    /// "Visual Studio Code" and "visual-studio-code" are too.
    static func normalise(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
