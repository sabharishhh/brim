import Foundation

/// Where Brim learned that a newer version exists. The first source that
/// answers for an application is the one it keeps, and the row says which.
public enum UpdateOrigin: Codable, Equatable, Sendable {
    /// Apple's catalogue, for an application with an App Store receipt.
    case appStore(trackID: Int)
    /// The Sparkle feed the application itself reads.
    case sparkle(feed: String)
    /// The `latest-mac.yml` an Electron application's own updater reads.
    case electron(feed: String)
    /// Homebrew's public catalogue, for an application Homebrew did not
    /// install. Used when the application names no feed of its own.
    case catalog(cask: String)
    /// Homebrew installed it, so Homebrew updates it.
    case homebrew(cask: String)

    /// Said in a few words, for the details.
    public var title: String {
        switch self {
        case .appStore: return "App Store"
        case .sparkle(let feed): return "Update feed at \(Self.host(feed))"
        case .electron(let feed): return "Update feed at \(Self.host(feed))"
        case .catalog: return "Homebrew catalogue"
        case .homebrew: return "Homebrew"
        }
    }

    static func host(_ feed: String) -> String {
        URL(string: feed)?.host ?? feed
    }
}

/// How an update is put in place.
public enum UpdateRoute: String, Codable, Equatable, Sendable {
    /// Brim downloads it, checks it, and replaces the application.
    case replace
    /// The App Store installs it. Brim opens the application's page.
    case appStore
    /// It comes as an installer package, which Installer runs.
    case installer
    /// Homebrew installed the application, so Homebrew updates it.
    case homebrew
    /// The feed offers no download, only a page to get it from.
    case website

    public var explanation: String {
        switch self {
        case .replace:
            return "Brim downloads it, checks it is signed by the same developer, "
                + "and replaces the app. The old version goes to the Trash."
        case .appStore: return "The App Store installs this update."
        case .installer: return "Brim checks the package's signature, then opens it in Installer."
        case .homebrew: return "Homebrew installed this app, so Homebrew updates it."
        case .website: return "The developer offers this version on their website."
        }
    }
}

/// What to download, and what it must match.
public struct UpdateDownload: Codable, Equatable, Sendable {
    public enum Integrity: Codable, Equatable, Sendable {
        /// Hex SHA-256, as Homebrew records it.
        case sha256(String)
        /// Base64 SHA-512, as electron-builder records it.
        case sha512(String)
        /// A Sparkle EdDSA signature, checked against the application's
        /// own public key.
        case edDSA(signature: String, publicKey: String)
        /// Nothing published. The developer's signature still has to match.
        case none
    }

    public let url: URL
    public let bytes: Int64?
    public let integrity: Integrity

    public init(url: URL, bytes: Int64?, integrity: Integrity) {
        self.url = url
        self.bytes = bytes
        self.integrity = integrity
    }

    /// Whether this is an installer package rather than an archive.
    public var isPackage: Bool {
        ["pkg", "mpkg"].contains(url.pathExtension.lowercased())
    }
}

/// A newer version of an installed application.
public struct AppUpdate: Codable, Equatable, Sendable, Identifiable {
    public let bundleID: String
    public let name: String
    public let appURL: URL
    public let installedVersion: String
    public let latestVersion: String
    /// The build number the source gives, compared with `CFBundleVersion`
    /// where the source has one.
    public let latestBuild: String?
    public let origin: UpdateOrigin
    public let route: UpdateRoute
    public let download: UpdateDownload?
    public let releaseNotes: String?
    public let releaseNotesURL: URL?
    public let releasedAt: Date?
    /// Where a person can get it by hand: the store page, or the site.
    public let pageURL: URL?

    public var id: String { appURL.path }

    public init(
        bundleID: String, name: String, appURL: URL, installedVersion: String,
        latestVersion: String, latestBuild: String? = nil, origin: UpdateOrigin,
        route: UpdateRoute, download: UpdateDownload? = nil, releaseNotes: String? = nil,
        releaseNotesURL: URL? = nil, releasedAt: Date? = nil, pageURL: URL? = nil
    ) {
        self.bundleID = bundleID
        self.name = name
        self.appURL = appURL
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.latestBuild = latestBuild
        self.origin = origin
        self.route = route
        self.download = download
        self.releaseNotes = releaseNotes
        self.releaseNotesURL = releaseNotesURL
        self.releasedAt = releasedAt
        self.pageURL = pageURL
    }
}

extension AppUpdate {
    /// The same update, installed another way.
    public func handled(by route: UpdateRoute, cask: String) -> AppUpdate {
        AppUpdate(
            bundleID: bundleID, name: name, appURL: appURL, installedVersion: installedVersion,
            latestVersion: latestVersion, latestBuild: latestBuild,
            origin: route == .homebrew ? .homebrew(cask: cask) : origin, route: route,
            download: download, releaseNotes: releaseNotes, releaseNotesURL: releaseNotesURL,
            releasedAt: releasedAt, pageURL: pageURL
        )
    }
}

/// An application Brim could not check, and why.
public struct UncheckedApp: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let appURL: URL
    public let reason: String

    public var id: String { appURL.path }

    public init(name: String, appURL: URL, reason: String) {
        self.name = name
        self.appURL = appURL
        self.reason = reason
    }
}

/// One check across every application.
public struct UpdateCheck: Codable, Equatable, Sendable {
    public let updates: [AppUpdate]
    /// How many applications a source answered for, updated or not.
    public let checked: Int
    public let unchecked: [UncheckedApp]
    public let checkedAt: Date
    /// Applications that took a new version in the last two weeks, by any
    /// route: the App Store, their own updater, or Brim.
    public var recent: [RecentUpdate]
    /// Updates Brim started that did not finish, found and settled the
    /// next time it looked. Keyed by the application's path.
    public var interrupted: [String: String]

    public init(
        updates: [AppUpdate], checked: Int, unchecked: [UncheckedApp], checkedAt: Date,
        recent: [RecentUpdate] = [], interrupted: [String: String] = [:]
    ) {
        self.updates = updates
        self.checked = checked
        self.unchecked = unchecked
        self.checkedAt = checkedAt
        self.recent = recent
        self.interrupted = interrupted
    }
}

/// One application that took a new version recently.
public struct RecentUpdate: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let appURL: URL
    /// The version Brim saw before, when it saw one.
    public let fromVersion: String?
    public let toVersion: String
    public let updatedAt: Date

    public var id: String { appURL.path }

    public init(name: String, appURL: URL, fromVersion: String?, toVersion: String, updatedAt: Date) {
        self.name = name
        self.appURL = appURL
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.updatedAt = updatedAt
    }
}

/// What happened when an update was asked for.
public enum UpdateOutcome: Codable, Equatable, Sendable {
    /// The new version is in place and reads back as `version`.
    case installed(version: String)
    /// The downloaded copy was not newer than the installed one.
    case alreadyCurrent
    /// Handed to Installer, which finishes it.
    case openedInstaller
    /// The application is still open and would not quit.
    case stillOpen(name: String)
    /// macOS would not let Brim change the folder the app is in, which is
    /// App Management's decision. Nothing was changed.
    case notAllowed(folder: String)
    case failed(String)
}

/// Orders version strings the way Sparkle does, closely enough: numbers
/// compare as numbers, a pre-release word sorts below the release it
/// precedes, and separators are ignored.
public enum VersionOrder {
    public static func compare(_ left: String, _ right: String) -> ComparisonResult {
        let a = tokens(left), b = tokens(right)
        for index in 0..<max(a.count, b.count) {
            guard index < a.count else { return remainder(b[index...]).inverted }
            guard index < b.count else { return remainder(a[index...]) }
            let x = a[index], y = b[index]
            switch (x.isNumber, y.isNumber) {
            case (true, true):
                let order = x.text.compare(y.text, options: .numeric)
                if order != .orderedSame { return order }
            case (false, false):
                let order = x.text.caseInsensitiveCompare(y.text)
                if order != .orderedSame { return order }
            case (true, false): return .orderedDescending
            case (false, true): return .orderedAscending
            }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    /// What the extra parts of the longer version make it. Zeros change
    /// nothing, a number makes it newer, and a word first makes it a
    /// pre-release of the shorter one: 1.2.0 is 1.2, 1.2.1 is newer, and
    /// 1.2b1 is older.
    private static func remainder(_ rest: ArraySlice<Token>) -> ComparisonResult {
        for token in rest {
            if token.isNumber {
                if Int(token.text) == 0 || token.text.allSatisfy({ $0 == "0" }) { continue }
                return .orderedDescending
            }
            return .orderedAscending
        }
        return .orderedSame
    }

    private struct Token { let text: String; let isNumber: Bool }

    private static func tokens(_ version: String) -> [Token] {
        var trimmed = Substring(version.trimmingCharacters(in: .whitespaces))
        if trimmed.first == "v" || trimmed.first == "V" { trimmed = trimmed.dropFirst() }
        var result: [Token] = []
        var current = ""
        var currentIsNumber = false
        for character in trimmed {
            let isDigit = character.isASCII && character.isNumber
            let isLetter = character.isLetter
            guard isDigit || isLetter else {
                if !current.isEmpty { result.append(Token(text: current, isNumber: currentIsNumber)) }
                current = ""
                continue
            }
            if !current.isEmpty, isDigit != currentIsNumber {
                result.append(Token(text: current, isNumber: currentIsNumber))
                current = ""
            }
            current.append(character)
            currentIsNumber = isDigit
        }
        if !current.isEmpty { result.append(Token(text: current, isNumber: currentIsNumber)) }
        return result
    }
}

private extension ComparisonResult {
    var inverted: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
