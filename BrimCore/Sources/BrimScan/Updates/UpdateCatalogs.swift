import BrimCore
import Foundation

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
    public var displayVersion: String {
        String(version.split(separator: ",").first ?? "")
    }
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
                if let name = item as? String {
                    names.insert((name as NSString).lastPathComponent.lowercased())
                }
            }
            if let target = artifact["target"] as? String, artifact["app"] != nil {
                names.insert((target as NSString).lastPathComponent.lowercased())
            }
            if artifact["pkg"] != nil {
                packages = true
            }
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

    /// Compiled once, not for every cask.
    private static let identifierPattern = try? NSRegularExpression(pattern: #"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}"#)

    /// Bundle identifiers a cask names in its uninstall and zap stanzas,
    /// which is how two casks installing an app of the same name are told
    /// apart.
    static func identifiers(in artifacts: [[String: Any]]) -> Set<String> {
        guard let data = try? JSONSerialization.data(withJSONObject: artifacts),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set((identifierPattern?.matches(in: text, range: range) ?? []).compactMap {
            Range($0.range, in: text).map { String(text[$0]).lowercased() }
        })
    }

    /// The cask for an installed application: the one whose application
    /// has this file name, and when several do, the one that names this
    /// bundle identifier. Anything still ambiguous is not a match.
    public static func match(fileName: String, bundleID: String?, in casks: [CatalogCask]) -> CatalogCask? {
        let name = fileName.lowercased()
        let named = casks.filter { $0.appNames.contains(name) }
        if named.count == 1 {
            return named[0]
        }
        guard let bundleID = bundleID?.lowercased() else { return nil }
        let identified = named.filter { $0.identifiers.contains(bundleID) }
        return identified.count == 1 ? identified[0] : nil
    }
}

// MARK: - App Store

public enum AppStoreCatalog {
    /// Built once, not for every listing. Safe to share between threads,
    /// as Apple documents; Swift cannot see that.
    private nonisolated(unsafe) static let releaseDates = ISO8601DateFormatter()

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
                    .flatMap { releaseDates.date(from: $0) },
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
