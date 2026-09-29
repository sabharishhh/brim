import BrimCore
import Foundation

/// Finds out, for every installed application, whether a newer version
/// exists.
///
/// One source per application, the application's own first: an App Store
/// receipt means Apple's catalogue, a Sparkle feed or an electron-builder
/// feed is where the application itself looks, and Homebrew's public
/// catalogue covers the rest, which is how Electron applications that set
/// their feed in code get checked at all. A source that does not answer
/// hands on to the next, and an application no source answers for is
/// reported as not checked, never as up to date.
///
/// MacUpdater kept its own list of 60,000 applications and closed when the
/// daily upkeep became too much; everything here is published by the
/// developers or maintained by Homebrew's contributors.
public struct UpdateFinder: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let fetch: Fetch
    private let catalogue: CatalogueCache
    private let platform: UpdatePlatform
    private let region: String
    private let installedCasks: Set<String>

    public init(
        fetch: @escaping Fetch = UpdateFinder.network,
        catalogueDirectory: URL,
        platform: UpdatePlatform = .current,
        region: String = Locale.current.region?.identifier ?? "US",
        installedCasks: Set<String> = UpdateSourceScanner().installedCasks()
    ) {
        self.fetch = fetch
        self.catalogue = CatalogueCache(directory: catalogueDirectory, fetch: fetch)
        self.platform = platform
        self.region = region
        self.installedCasks = installedCasks
    }

    public static let network: Fetch = { request in
        var request = request
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// What one source says about one application.
    enum Answer: Sendable {
        case update(AppUpdate)
        case current
        case noAnswer

        var isSilent: Bool {
            if case .noAnswer = self { return true }
            return false
        }
    }

    public func check(_ applications: [InstalledApplication], now: Date = Date()) async -> UpdateCheck {
        let candidates = applications.compactMap { application in
            Self.candidate(application, among: applications)
        }
        let storeBundles = candidates.filter(\.hasReceipt).compactMap(\.bundleID)
        let listings = await storeListings(storeBundles)

        let answers = (try? await BoundedTasks.map(candidates, limit: 6) { candidate in
            (candidate, await self.answer(for: candidate, listings: listings))
        }) ?? []

        var updates: [AppUpdate] = []
        var unchecked: [UncheckedApp] = []
        for (candidate, answer) in answers {
            switch answer {
            case .update(let update): updates.append(update)
            case .current: break
            case .noAnswer:
                unchecked.append(UncheckedApp(
                    name: candidate.name, appURL: candidate.url,
                    reason: candidate.hasOwnSource ? "Its update source did not answer." : "No update source."
                ))
            }
        }
        return UpdateCheck(
            updates: updates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            checked: answers.count - unchecked.count,
            unchecked: unchecked.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            checkedAt: now
        )
    }

    // MARK: - Which applications

    struct Candidate: Sendable {
        let application: InstalledApplication
        let name: String
        let url: URL
        let bundleID: String?
        let version: String
        let build: String?
        let info: [String: String]
        let hasReceipt: Bool
        let hasElectronFeed: Bool

        var hasOwnSource: Bool { hasReceipt || info["SUFeedURL"] != nil || hasElectronFeed }
    }

    /// Applications something can update. macOS updates its own; an
    /// application inside another is updated with it; a web app shim
    /// belongs to its browser; Setapp updates its own catalogue; and a
    /// bundle with no version has nothing to compare.
    static func candidate(_ application: InstalledApplication, among all: [InstalledApplication]) -> Candidate? {
        let contents = application.url.appendingPathComponent("Contents")
        let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        let bundleID = plist["CFBundleIdentifier"] as? String
        let hasReceipt = FileManager.default.fileExists(atPath: contents.appendingPathComponent("_MASReceipt/receipt").path)
        guard !application.isSystemProtected, application.enclosingApp == nil,
              let version = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String,
              !version.isEmpty
        else { return nil }
        if let bundleID {
            let lowered = bundleID.lowercased()
            if lowered.hasPrefix("com.apple.") && !hasReceipt { return nil }
            if lowered.hasSuffix("-setapp") { return nil }
            if all.contains(where: { other in
                guard let theirs = other.identity.bundleID?.lowercased(), theirs != lowered else { return false }
                return lowered.hasPrefix(theirs + ".")
            }) { return nil }
        }
        var info: [String: String] = [:]
        for key in ["SUFeedURL", "SUPublicEDKey", "LSMinimumSystemVersion"] {
            if let value = plist[key] as? String, !value.isEmpty { info[key] = value }
        }
        return Candidate(
            application: application, name: application.name, url: application.url, bundleID: bundleID, version: version,
            build: plist["CFBundleVersion"] as? String, info: info, hasReceipt: hasReceipt,
            hasElectronFeed: FileManager.default.fileExists(
                atPath: contents.appendingPathComponent("Resources/app-update.yml").path)
        )
    }

    // MARK: - Asking

    private func answer(for candidate: Candidate, listings: [String: AppStoreCatalog.Listing]?) async -> Answer {
        if candidate.hasReceipt {
            return await appStore(candidate, listings: listings)
        }
        let cask = UpdateSourceScanner.matchingCask(for: candidate.application, among: installedCasks)
        if let cask, case let answer = await homebrew(candidate, cask: cask), !answer.isSilent { return answer }
        for answer in [await sparkle(candidate), await electron(candidate)] where !answer.isSilent {
            // A cask from a third-party tap is not in the public
            // catalogue. The application's own feed says what is new, and
            // Homebrew still installs it, so its records stay right.
            guard let cask, case .update(let update) = answer else { return answer }
            return .update(update.handled(by: .homebrew, cask: cask))
        }
        return cask == nil ? await catalogueAnswer(candidate) : .noAnswer
    }

    private func storeListings(_ bundleIDs: [String]) async -> [String: AppStoreCatalog.Listing]? {
        guard !bundleIDs.isEmpty,
              let url = AppStoreCatalog.lookupURL(bundleIDs: bundleIDs, region: region),
              let (data, response) = try? await fetch(URLRequest(url: url)),
              response.statusCode == 200
        else { return bundleIDs.isEmpty ? [:] : nil }
        return AppStoreCatalog.listings(from: data)
    }

    private func appStore(_ candidate: Candidate, listings: [String: AppStoreCatalog.Listing]?) async -> Answer {
        guard let bundleID = candidate.bundleID, let listing = listings?[bundleID.lowercased()] else {
            return .noAnswer
        }
        guard VersionOrder.isNewer(listing.version, than: candidate.version) else { return .current }
        // A shared listing's version may be the iPhone's. The Mac page
        // decides, and a page that cannot be read means not checked,
        // never an update the App Store will not offer.
        var latest = listing.version
        if listing.isShared {
            guard let url = AppStoreCatalog.macPageURL(trackID: listing.trackID, region: region),
                  let (data, response) = try? await fetch(URLRequest(url: url)), response.statusCode == 200,
                  let mac = AppStoreCatalog.macVersion(fromPage: String(decoding: data, as: UTF8.self))
            else { return .noAnswer }
            guard VersionOrder.isNewer(mac, than: candidate.version) else { return .current }
            latest = mac
        }
        return .update(AppUpdate(
            bundleID: bundleID, name: candidate.name, appURL: candidate.url,
            installedVersion: candidate.version, latestVersion: latest,
            origin: .appStore(trackID: listing.trackID), route: .appStore,
            releaseNotes: latest == listing.version ? listing.notes : nil,
            releasedAt: latest == listing.version ? listing.released : nil,
            pageURL: URL(string: "macappstore://apps.apple.com/app/id\(listing.trackID)")
        ))
    }

    private func sparkle(_ candidate: Candidate) async -> Answer {
        guard let feed = candidate.info["SUFeedURL"] ?? Self.feedFromPreferences(candidate.bundleID),
              let url = URL(string: feed.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))),
              url.scheme == "https",
              let (data, response) = try? await fetch(URLRequest(url: url)), response.statusCode == 200
        else { return .noAnswer }
        guard let item = SparkleAppcast.best(in: SparkleAppcast.items(in: data), for: platform),
              let display = item.displayVersion
        else { return .noAnswer }
        let newer = item.version.map { build in candidate.build.map { VersionOrder.isNewer(build, than: $0) } ?? false }
            ?? VersionOrder.isNewer(display, than: candidate.version)
        guard newer, let bundleID = candidate.bundleID else { return .current }

        var download: UpdateDownload?
        var route = UpdateRoute.website
        if !item.informational, let link = item.enclosureURL, let enclosure = URL(string: link), enclosure.scheme == "https" {
            let integrity: UpdateDownload.Integrity =
                if let signature = item.edSignature, let key = candidate.info["SUPublicEDKey"] {
                    .edDSA(signature: signature, publicKey: key)
                } else { .none }
            download = UpdateDownload(url: enclosure, bytes: item.enclosureLength, integrity: integrity)
            let packaged = ["package", "interactive-package"].contains(item.installationType ?? "") || download?.isPackage == true
            route = packaged ? .installer : .replace
        }
        return .update(AppUpdate(
            bundleID: bundleID, name: candidate.name, appURL: candidate.url,
            installedVersion: candidate.version, latestVersion: display, latestBuild: item.version,
            origin: .sparkle(feed: feed), route: route, download: download,
            releaseNotes: item.notes.map(Self.plainText),
            releaseNotesURL: item.releaseNotesLink.flatMap(URL.init(string:)),
            releasedAt: item.date, pageURL: item.link.flatMap(URL.init(string:))
        ))
    }

    private func electron(_ candidate: Candidate) async -> Answer {
        guard candidate.hasElectronFeed,
              let text = try? String(contentsOf: candidate.url.appendingPathComponent("Contents/Resources/app-update.yml"),
                                     encoding: .utf8),
              let feed = ElectronFeed.feed(fromConfiguration: text),
              let (data, response) = try? await fetch(URLRequest(url: feed.manifest)), response.statusCode == 200,
              let manifest = ElectronFeed.manifest(from: String(decoding: data, as: UTF8.self))
        else { return .noAnswer }
        guard VersionOrder.isNewer(manifest.version, than: candidate.version) else { return .current }
        guard let bundleID = candidate.bundleID,
              let file = ElectronFeed.file(in: manifest, for: platform),
              let url = feed.files(file.url, manifest.version)
        else { return .noAnswer }
        return .update(AppUpdate(
            bundleID: bundleID, name: candidate.name, appURL: candidate.url,
            installedVersion: candidate.version, latestVersion: manifest.version,
            origin: .electron(feed: feed.manifest.absoluteString), route: .replace,
            download: UpdateDownload(url: url, bytes: file.size,
                                     integrity: file.sha512.map { .sha512($0) } ?? .none),
            releasedAt: manifest.releaseDate
        ))
    }

    private func catalogueAnswer(_ candidate: Candidate) async -> Answer {
        guard let casks = await catalogue.casks(),
              let cask = HomebrewCatalog.match(fileName: candidate.url.lastPathComponent,
                                               bundleID: candidate.bundleID, in: casks)
        else { return .noAnswer }
        return update(candidate, from: cask, origin: .catalog(cask: cask.token))
    }

    private func homebrew(_ candidate: Candidate, cask token: String) async -> Answer {
        guard let casks = await catalogue.casks(), let cask = casks.first(where: { $0.token == token }) else {
            return .noAnswer
        }
        return update(candidate, from: cask, origin: .homebrew(cask: token))
    }

    private func update(_ candidate: Candidate, from cask: CatalogCask, origin: UpdateOrigin) -> Answer {
        // Only strictly newer: the catalogue sometimes trails the
        // developer, and an older version is not an update.
        guard VersionOrder.isNewer(cask.displayVersion, than: candidate.version) else { return .current }
        guard let bundleID = candidate.bundleID, platform.canRun(minimum: cask.minimumSystem),
              let url = URL(string: cask.url)
        else { return .current }
        let route: UpdateRoute =
            if case .homebrew = origin { .homebrew } else if cask.installsPackage { .installer } else { .replace }
        return .update(AppUpdate(
            bundleID: bundleID, name: candidate.name, appURL: candidate.url,
            installedVersion: candidate.version, latestVersion: cask.displayVersion,
            origin: origin, route: route,
            download: UpdateDownload(url: url, bytes: nil, integrity: cask.sha256.map { .sha256($0) } ?? .none),
            pageURL: cask.homepage.flatMap(URL.init(string:))
        ))
    }

    /// Sparkle 1 saved a feed set in code to the application's defaults.
    static func feedFromPreferences(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return CFPreferencesCopyAppValue("SUFeedURL" as CFString, bundleID as CFString) as? String
    }

    /// Release notes in feeds are HTML. The details show them as text.
    static func plainText(_ html: String) -> String {
        guard html.contains("<"), let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil)
        else { return html }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Homebrew's catalogue, fetched at most once a day and only when an
/// application needs it. The response carries an ETag, so a fetch when
/// nothing changed costs a few hundred bytes.
actor CatalogueCache {
    private let directory: URL
    private let fetch: UpdateFinder.Fetch
    private var loading: Task<[CatalogCask]?, Never>?
    static let source = URL(string: "https://formulae.brew.sh/api/cask.json")!

    init(directory: URL, fetch: @escaping UpdateFinder.Fetch) {
        self.directory = directory
        self.fetch = fetch
    }

    /// One load, shared. Applications ask at the same time, and an actor
    /// lets the second one in while the first is waiting on the network:
    /// a flag set before the download told every other application there
    /// was no catalogue.
    func casks() async -> [CatalogCask]? {
        if let loading { return await loading.value }
        let task = Task { await load() }
        loading = task
        return await task.value
    }

    private func load() async -> [CatalogCask]? {
        let file = directory.appendingPathComponent("cask.json")
        let tag = directory.appendingPathComponent("cask.etag")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        if age > 24 * 3600 {
            var request = URLRequest(url: Self.source)
            if age.isFinite, let etag = try? String(contentsOf: tag, encoding: .utf8) {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let (data, response) = try? await fetch(request) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if response.statusCode == 200, !data.isEmpty {
                    try? data.write(to: file, options: .atomic)
                    if let etag = response.value(forHTTPHeaderField: "ETag") {
                        try? etag.write(to: tag, atomically: true, encoding: .utf8)
                    }
                } else if response.statusCode == 304 {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                }
            }
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        let casks = HomebrewCatalog.casks(from: data)
        return casks.isEmpty ? nil : casks
    }
}
