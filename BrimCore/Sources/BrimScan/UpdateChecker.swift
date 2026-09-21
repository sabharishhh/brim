import Foundation
import BrimCore

/// Finds out whether there is actually a newer version, and installs it.
///
/// The section used to report which *mechanism* could update each
/// application and call that Updates. It answered a question nobody asks.
/// "Ten applications have no way to update themselves" does not say
/// whether anything needs updating, and a row telling somebody to go and
/// type `brew upgrade` is the app declining to do the one thing it is
/// for.
///
/// Checking reaches the network, so it happens on a press and never
/// during a scan. Installing is by delegation: Homebrew upgrades its own
/// casks, the App Store updates its own purchases, and a Sparkle
/// application updates itself. Brim drives them and downloads nothing.
public struct UpdateChecker: Sendable {

    private let brewPath: String
    private let session: URLSession

    public init(
        brewPath: String = "/opt/homebrew/bin/brew",
        session: URLSession = .shared
    ) {
        self.brewPath = brewPath
        self.session = session
    }

    public func homebrewIsAvailable(fileManager: FileManager = .default) -> Bool {
        fileManager.isExecutableFile(atPath: brewPath)
            || fileManager.isExecutableFile(atPath: "/usr/local/bin/brew")
    }

    private var resolvedBrew: String? {
        let manager = FileManager.default
        if manager.isExecutableFile(atPath: brewPath) { return brewPath }
        if manager.isExecutableFile(atPath: "/usr/local/bin/brew") { return "/usr/local/bin/brew" }
        return nil
    }

    // MARK: - Homebrew

    /// Which casks Homebrew has a newer version of.
    ///
    /// `--greedy` because a cask that updates itself is still a cask
    /// Homebrew tracks, and leaving those out means the count on screen
    /// disagrees with what `brew upgrade` would do.
    public func outdatedCasks() async -> [String: (installed: String?, latest: String)] {
        guard let brew = resolvedBrew else { return [:] }
        guard let output = ToolOutput.read(
            brew, ["outdated", "--cask", "--greedy", "--json"], timeout: 90
        ) else { return [:] }
        return Self.parseOutdated(output)
    }

    /// `brew outdated --json` prints a preamble while it downloads its
    /// index, so the JSON starts at the first brace rather than the first
    /// byte.
    static func parseOutdated(
        _ output: String
    ) -> [String: (installed: String?, latest: String)] {
        guard let start = output.firstIndex(of: "{") else { return [:] }
        let json = String(output[start...])
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = parsed["casks"] as? [[String: Any]]
        else { return [:] }

        var result: [String: (installed: String?, latest: String)] = [:]
        for cask in casks {
            guard let name = cask["name"] as? String,
                  let latest = cask["current_version"] as? String
            else { continue }
            let installed = (cask["installed_versions"] as? [String])?.first
            result[name] = (installed: installed, latest: latest)
        }
        return result
    }

    /// Upgrades one cask. Homebrew does the download and the install.
    ///
    /// A fixed executable and fixed arguments, with the cask name checked
    /// for shape first: it comes from Homebrew's own listing, but it
    /// reaches a subprocess and the step vocabulary's rule about never
    /// composing a command holds here too.
    public func upgradeCask(_ name: String) async -> String? {
        guard Self.isPlausibleCaskName(name) else {
            return "\"\(name)\" is not a cask name."
        }
        guard let brew = resolvedBrew else {
            return "Homebrew is not installed."
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["upgrade", "--cask", name]
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        let details = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return nil }
        let message = String(data: details, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty
            ? "Homebrew could not update \(name)."
            : message.split(separator: "\n").suffix(3).joined(separator: " ")
    }

    /// Removes a cask's record. Used when Homebrew is tracking something
    /// whose application is not on the disk.
    public func uninstallCask(_ name: String) async -> String? {
        guard Self.isPlausibleCaskName(name) else { return "\"\(name)\" is not a cask name." }
        guard let brew = resolvedBrew else { return "Homebrew is not installed." }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["uninstall", "--cask", "--force", name]
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors
        do { try process.run() } catch { return error.localizedDescription }
        let details = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return nil }
        let message = String(data: details, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "Homebrew could not remove \(name)." : message
    }

    public static func isPlausibleCaskName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128
            && !name.hasPrefix("-")
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "@" }
    }

    // MARK: - Sparkle

    /// The newest version a Sparkle feed advertises.
    ///
    /// One request per feed, on a press. The feed URL comes out of the
    /// application's own `Info.plist`, so nothing is contacted that the
    /// installed software would not contact itself.
    public func latestVersion(fromFeed feed: String) async -> String? {
        guard let url = URL(string: feed), url.scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return Self.newestVersion(inAppcast: data)
    }

    /// Reads `sparkle:shortVersionString` out of an appcast.
    ///
    /// The short string rather than `sparkle:version`, because the latter
    /// is a build number a person never sees and comparing it against the
    /// `CFBundleShortVersionString` Brim has would compare two different
    /// things.
    static func newestVersion(inAppcast data: Data) -> String? {
        let reader = AppcastReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return reader.versions
            .max { isOlder($0, than: $1) }
    }

    /// Whether one version string is older than another.
    ///
    /// Numeric comparison, so 1.10 is newer than 1.9 rather than
    /// alphabetically earlier. Anything that is not a plain dotted
    /// version is left alone: guessing at a scheme nobody defined is how
    /// an update notice appears for a version already installed.
    public static func isOlder(_ left: String, than right: String) -> Bool {
        left.compare(right, options: .numeric) == .orderedAscending
    }

    /// True only when the feed's newest is genuinely ahead of what is
    /// installed. Equal or unknown means no update, because a false
    /// notice is worse than a missed one.
    public static func isNewer(_ latest: String, than installed: String?) -> Bool {
        guard let installed, !installed.isEmpty, !latest.isEmpty else { return false }
        return isOlder(installed, than: latest)
    }

    private final class AppcastReader: NSObject, XMLParserDelegate {
        var versions: [String] = []
        private var current: String?
        private var buffer = ""

        func parser(
            _ parser: XMLParser, didStartElement element: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            if element == "sparkle:shortVersionString" {
                current = element
                buffer = ""
            }
            // Some feeds put it on the enclosure instead.
            if element == "enclosure",
               let version = attributes["sparkle:shortVersionString"], !version.isEmpty {
                versions.append(version)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard current != nil else { return }
            buffer += string
        }

        func parser(
            _ parser: XMLParser, didEndElement element: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            guard element == current else { return }
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { versions.append(trimmed) }
            current = nil
            buffer = ""
        }
    }
}
