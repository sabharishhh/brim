import BrimCore
import Foundation

/// The machine a download has to run on.
public struct UpdatePlatform: Sendable {
    public let system: OperatingSystemVersion
    public let isAppleSilicon: Bool

    public init(system: OperatingSystemVersion, isAppleSilicon: Bool) {
        self.system = system
        self.isAppleSilicon = isAppleSilicon
    }

    public static var current: UpdatePlatform {
        #if arch(arm64)
        UpdatePlatform(system: ProcessInfo.processInfo.operatingSystemVersion, isAppleSilicon: true)
        #else
        UpdatePlatform(system: ProcessInfo.processInfo.operatingSystemVersion, isAppleSilicon: false)
        #endif
    }

    var systemString: String { "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)" }

    func canRun(minimum: String?) -> Bool {
        guard let minimum, !minimum.isEmpty else { return true }
        return VersionOrder.compare(minimum, systemString) != .orderedDescending
    }

    func canRun(maximum: String?) -> Bool {
        guard let maximum, !maximum.isEmpty else { return true }
        return VersionOrder.compare(maximum, systemString) != .orderedAscending
    }
}

// MARK: - Sparkle

/// One release in a Sparkle appcast.
public struct AppcastItem: Equatable, Sendable {
    public var version: String?
    public var shortVersion: String?
    public var minimumSystem: String?
    public var maximumSystem: String?
    public var hardware: String?
    public var channel: String?
    public var informational = false
    public var link: String?
    public var releaseNotesLink: String?
    public var notes: String?
    public var date: Date?
    public var enclosureURL: String?
    public var enclosureLength: Int64?
    public var edSignature: String?
    public var installationType: String?

    /// What a person sees, falling back to the build when a feed gives
    /// nothing else.
    public var displayVersion: String? { shortVersion ?? version }
}

/// Reads an appcast the way Sparkle chooses from it.
///
/// Brim used to take the largest `shortVersionString` it could find, which
/// compared a marketing string with a numeric string compare and ignored
/// everything Sparkle itself checks: the build number it actually orders
/// by, the macOS range an item declares, Apple silicon requirements,
/// channels a person never subscribed to, and items that offer no download
/// at all.
public enum SparkleAppcast {
    public static func items(in data: Data) -> [AppcastItem] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        return parser.parse() ? reader.items : []
    }

    /// The newest item this Mac can install from the default channel.
    public static func best(in items: [AppcastItem], for platform: UpdatePlatform) -> AppcastItem? {
        items.filter { item in
            item.channel == nil
                && item.displayVersion != nil
                && platform.canRun(minimum: item.minimumSystem)
                && platform.canRun(maximum: item.maximumSystem)
                && (platform.isAppleSilicon || !(item.hardware ?? "").contains("arm64"))
        }
        .max { VersionOrder.compare(orderKey($0), orderKey($1)) == .orderedAscending }
    }

    /// Sparkle orders by `sparkle:version`, which is `CFBundleVersion`.
    static func orderKey(_ item: AppcastItem) -> String { item.version ?? item.shortVersion ?? "" }

    private final class Reader: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""
        private var deltaDepth = 0
        nonisolated(unsafe) private static let dateFormat: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return formatter
        }()

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch element {
            case "item": current = AppcastItem()
            case "sparkle:deltas": deltaDepth += 1
            case "sparkle:informationalUpdate": current?.informational = true
            case "enclosure" where deltaDepth == 0:
                // An item can carry one enclosure per operating system.
                guard current != nil, current?.enclosureURL == nil,
                      attributes["sparkle:os"].map({ $0 == "macos" }) ?? true else { return }
                current?.enclosureURL = attributes["url"]
                current?.enclosureLength = attributes["length"].flatMap(Int64.init)
                current?.edSignature = attributes["sparkle:edSignature"]
                current?.installationType = attributes["sparkle:installationType"]
                if current?.version == nil { current?.version = attributes["sparkle:version"] }
                if current?.shortVersion == nil { current?.shortVersion = attributes["sparkle:shortVersionString"] }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            text += String(data: block, encoding: .utf8) ?? ""
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            guard deltaDepth == 0 || element == "sparkle:deltas" else { return }
            switch element {
            case "sparkle:deltas": deltaDepth -= 1
            case "item":
                if let current { items.append(current) }
                current = nil
            case "sparkle:version" where !value.isEmpty: current?.version = value
            case "sparkle:shortVersionString" where !value.isEmpty: current?.shortVersion = value
            case "sparkle:minimumSystemVersion": current?.minimumSystem = value
            case "sparkle:maximumSystemVersion": current?.maximumSystem = value
            case "sparkle:hardwareRequirements": current?.hardware = value
            case "sparkle:channel" where !value.isEmpty: current?.channel = value
            case "sparkle:releaseNotesLink": current?.releaseNotesLink = value
            case "link" where current != nil: current?.link = value
            case "description" where current != nil && !value.isEmpty: current?.notes = value
            case "pubDate": current?.date = Self.dateFormat.date(from: value)
            default: break
            }
        }
    }
}

// MARK: - Electron

/// electron-builder's update metadata.
///
/// An Electron application built with electron-builder ships
/// `Contents/Resources/app-update.yml`, which says where its updater looks,
/// and the place it names publishes `latest-mac.yml` with the version and
/// a SHA-512 for each file. Both are flat enough to read by line.
public enum ElectronFeed {
    public struct Manifest: Equatable, Sendable {
        public let version: String
        public let files: [(url: String, sha512: String?, size: Int64?)]
        public let releaseDate: Date?

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.version == rhs.version && lhs.files.map(\.url) == rhs.files.map(\.url)
        }
    }

    /// Where `latest-mac.yml` is, and where the files it names are, from
    /// the application's `app-update.yml`.
    public static func feed(fromConfiguration text: String) -> (manifest: URL, files: (String, String) -> URL?)? {
        let values = keyValues(text)
        let channel = values["channel"].map { "\($0)-mac.yml" } ?? "latest-mac.yml"
        switch values["provider"] {
        case "github":
            guard let owner = values["owner"], let repo = values["repo"],
                  let manifest = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/\(channel)")
            else { return nil }
            let prefix = values["tagNamePrefix"] ?? "v"
            return (manifest, { file, version in
                URL(string: file).flatMap { $0.scheme == "https" ? $0 : nil }
                    ?? URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(prefix)\(version)/")?
                        .appendingPathComponent(file)
            })
        case "generic":
            guard var base = values["url"], base.hasPrefix("https://") else { return nil }
            if !base.hasSuffix("/") { base += "/" }
            guard let root = URL(string: base) else { return nil }
            return (root.appendingPathComponent(channel), { file, _ in
                URL(string: file).flatMap { $0.scheme == "https" ? $0 : nil } ?? root.appendingPathComponent(file)
            })
        default:
            return nil
        }
    }

    public static func manifest(from text: String) -> Manifest? {
        var version: String?
        var date: Date?
        var files: [(url: String, sha512: String?, size: Int64?)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- url:") {
                files.append((value(trimmed.dropFirst(2)), nil, nil))
            } else if line.hasPrefix(" "), !files.isEmpty, trimmed.hasPrefix("sha512:") {
                files[files.count - 1].sha512 = value(Substring(trimmed))
            } else if line.hasPrefix(" "), !files.isEmpty, trimmed.hasPrefix("size:") {
                files[files.count - 1].size = Int64(value(Substring(trimmed)))
            } else if line.hasPrefix("version:") {
                version = value(Substring(line))
            } else if line.hasPrefix("releaseDate:") {
                date = ISO8601DateFormatter.withFraction.date(from: value(Substring(line)))
            }
        }
        guard let version, !version.isEmpty, !files.isEmpty else { return nil }
        return Manifest(version: version, files: files, releaseDate: date)
    }

    /// The file this Mac should take: a zip, for its own architecture when
    /// there is a choice.
    public static func file(in manifest: Manifest, for platform: UpdatePlatform)
        -> (url: String, sha512: String?, size: Int64?)? {
        let archives = manifest.files.filter { $0.url.lowercased().hasSuffix(".zip") }
        let own = platform.isAppleSilicon ? "arm64" : "x64"
        let other = platform.isAppleSilicon ? "x64" : "arm64"
        return archives.first { $0.url.contains(own) }
            ?? archives.first { $0.url.contains("universal") }
            ?? archives.first { !$0.url.contains(other) && !$0.url.contains(own) }
    }

    static func keyValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix(" ") && !line.hasPrefix("#") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            values[key] = value(line)
        }
        return values
    }

    private static func value(_ line: Substring) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Homebrew catalogue

/// One cask from Homebrew's public catalogue, reduced to what matching and
/// downloading need.
public struct CatalogCask: Equatable, Sendable {
    public let token: String
    public let version: String
    public let appNames: Set<String>
    public let identifiers: Set<String>
    public let url: String
    public let sha256: String?
    public let installsPackage: Bool
    public let minimumSystem: String?
    public let homepage: String?

    /// The version a person sees: Homebrew appends build details after a
    /// comma, as in `2.17.0,5217732355031040`.
    public var displayVersion: String { String(version.split(separator: ",").first ?? "") }
}

public enum HomebrewCatalog {
    /// Reads `cask.json`, keeping only casks that install an application
    /// and have a version to compare.
    public static func casks(from data: Data) -> [CatalogCask] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap(cask)
    }

    static func cask(_ entry: [String: Any]) -> CatalogCask? {
        guard let token = entry["token"] as? String,
              let version = entry["version"] as? String, version != "latest",
              let url = entry["url"] as? String, url.hasPrefix("https://"),
              (entry["deprecated"] as? Bool) != true, (entry["disabled"] as? Bool) != true,
              let artifacts = entry["artifacts"] as? [[String: Any]]
        else { return nil }
        var names = Set<String>()
        var packages = false
        for artifact in artifacts {
            for item in artifact["app"] as? [Any] ?? [] {
                if let name = item as? String { names.insert((name as NSString).lastPathComponent.lowercased()) }
            }
            if let target = artifact["target"] as? String, artifact["app"] != nil {
                names.insert((target as NSString).lastPathComponent.lowercased())
            }
            if artifact["pkg"] != nil { packages = true }
        }
        guard !names.isEmpty || packages else { return nil }
        let sha = entry["sha256"] as? String
        let minimum = ((entry["depends_on"] as? [String: Any])?["macos"] as? [String: Any])?[">="] as? [String]
        return CatalogCask(
            token: token, version: version, appNames: names,
            identifiers: identifiers(in: artifacts), url: url,
            sha256: sha == "no_check" ? nil : sha, installsPackage: packages,
            minimumSystem: minimum?.first, homepage: entry["homepage"] as? String
        )
    }

    /// Bundle identifiers a cask names in its uninstall and zap stanzas,
    /// which is how two casks installing an app of the same name are told
    /// apart.
    static func identifiers(in artifacts: [[String: Any]]) -> Set<String> {
        guard let data = try? JSONSerialization.data(withJSONObject: artifacts),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let pattern = try? NSRegularExpression(pattern: #"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}"#)
        let range = NSRange(text.startIndex..., in: text)
        return Set((pattern?.matches(in: text, range: range) ?? []).compactMap {
            Range($0.range, in: text).map { String(text[$0]).lowercased() }
        })
    }

    /// The cask for an installed application: the one whose application
    /// has this file name, and when several do, the one that names this
    /// bundle identifier. Anything still ambiguous is not a match.
    public static func match(fileName: String, bundleID: String?, in casks: [CatalogCask]) -> CatalogCask? {
        let name = fileName.lowercased()
        let named = casks.filter { $0.appNames.contains(name) }
        if named.count == 1 { return named[0] }
        guard let bundleID = bundleID?.lowercased() else { return nil }
        let identified = named.filter { $0.identifiers.contains(bundleID) }
        return identified.count == 1 ? identified[0] : nil
    }
}

// MARK: - App Store

public enum AppStoreCatalog {
    public struct Listing: Equatable, Sendable {
        public let bundleID: String
        public let version: String
        public let trackID: Int
        public let notes: String?
        public let released: Date?
        public let minimumSystem: String?
        /// A listing shared with iPhone and iPad carries one version for
        /// all of them, and it can be the iPhone's. Prime Video's said
        /// 10.150.2 while the Mac build was 10.148.
        public var isShared = false
    }

    /// Apple's lookup, which answers for many identifiers in one request.
    public static func lookupURL(bundleIDs: [String], region: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIDs.joined(separator: ",")),
            URLQueryItem(name: "entity", value: "macSoftware"),
            URLQueryItem(name: "country", value: region)
        ]
        return components?.url
    }

    public static func listings(from data: Data) -> [String: Listing] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [:] }
        var listings: [String: Listing] = [:]
        for result in results {
            guard let bundleID = result["bundleId"] as? String,
                  let version = result["version"] as? String,
                  let trackID = result["trackId"] as? Int else { continue }
            listings[bundleID.lowercased()] = Listing(
                bundleID: bundleID, version: version, trackID: trackID,
                notes: result["releaseNotes"] as? String,
                released: (result["currentVersionReleaseDate"] as? String)
                    .flatMap { ISO8601DateFormatter().date(from: $0) },
                minimumSystem: result["minimumOsVersion"] as? String,
                isShared: (result["kind"] as? String) != "mac-software"
            )
        }
        return listings
    }

    /// The App Store's page for the Mac edition, which states the Mac
    /// build's own version.
    public static func macPageURL(trackID: Int, region: String) -> URL? {
        URL(string: "https://apps.apple.com/\(region.lowercased())/app/id\(trackID)?platform=mac")
    }

    /// The newest version the Mac page lists: the first entry of its
    /// version history, or the version under "What's New".
    public static func macVersion(fromPage html: String) -> String? {
        for pattern in [#""primarySubtitle":"Version ([0-9][^"]*)""#, #">Version ([0-9][0-9A-Za-z.\-]*)</"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            return String(html[range])
        }
        return nil
    }
}
