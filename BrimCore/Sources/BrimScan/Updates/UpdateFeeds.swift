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

    var systemString: String {
        "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
    }

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
    public var displayVersion: String? {
        shortVersion ?? version
    }
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
    static func orderKey(_ item: AppcastItem) -> String {
        item.version ?? item.shortVersion ?? ""
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""
        private var deltaDepth = 0
        private static let dateFormat: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return formatter
        }()

        func parser(
            _: XMLParser, didStartElement element: String, namespaceURI _: String?,
            qualifiedName _: String?, attributes: [String: String] = [:]
        ) {
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
                if current?.version == nil {
                    current?.version = attributes["sparkle:version"]
                }
                if current?.shortVersion == nil {
                    current?.shortVersion = attributes["sparkle:shortVersionString"]
                }
            default: break
            }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_: XMLParser, foundCDATA block: Data) {
            text += String(data: block, encoding: .utf8) ?? ""
        }

        func parser(
            _: XMLParser, didEndElement element: String, namespaceURI _: String?, qualifiedName _: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            guard deltaDepth == 0 || element == "sparkle:deltas" else { return }
            switch element {
            case "sparkle:deltas": deltaDepth -= 1
            case "item":
                if let current {
                    items.append(current)
                }
                current = nil
            default: setMetadata(element, value: value)
            }
        }

        private func setMetadata(_ element: String, value: String) {
            switch element {
            case "sparkle:version", "sparkle:shortVersionString":
                setVersion(element, value: value)
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

        private func setVersion(_ element: String, value: String) {
            guard !value.isEmpty else { return }
            if element == "sparkle:version" {
                current?.version = value
            } else {
                current?.shortVersion = value
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
    public struct File: Sendable {
        public var url: String
        public var sha512: String?
        public var size: Int64?
    }

    public struct Manifest: Equatable, Sendable {
        public let version: String
        public let files: [File]
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
            if !base.hasSuffix("/") {
                base += "/"
            }
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
        var files: [File] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- url:") {
                files.append(File(url: value(trimmed.dropFirst(2)), sha512: nil, size: nil))
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
    public static func file(in manifest: Manifest, for platform: UpdatePlatform) -> File? {
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
