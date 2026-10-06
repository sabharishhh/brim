import BrimCore
import CoreServices
import Foundation
import Security

/// Lists the applications installed on a machine.
///
/// Resolves each bundle through `IdentityResolver`, so the identity the list
/// shows is the same one an uninstall will plan against — the name in the UI
/// and the subject of the plan can never drift apart.
public actor ApplicationInventory {
    private let root: FileSystemRoot
    private let resolver: IdentityResolver

    public init(root: FileSystemRoot) {
        self.root = root
        resolver = IdentityResolver(root: root)
    }

    /// Domains searched, in the order results are merged. `/System/Applications`
    /// is included because the user expects to *see* those apps, but they are
    /// marked protected rather than presented as removable.
    private var searchDomains: [(url: URL, protected: Bool)] {
        [
            (root.url(for: .applications), false),
            (root.url(for: .userApplications), false),
            (root.rootURL.appendingPathComponent("System/Applications"), true)
        ]
    }

    public func installedApplications() async -> [InstalledApplication] {
        var seen = Set<String>()
        var results: [InstalledApplication] = []
        let casks = UpdateSourceScanner().installedCaskInventory()
        var developers = DeveloperNames()

        // A bundle reachable from two domains is one application.
        let unique = candidates().filter { seen.insert($0.url.standardizedFileURL.path).inserted }
        // Judge protection and size by where the bundle actually is, not by
        // where it is listed: /Applications/Safari.app is a symlink into a
        // Cryptex, so a check on the listed path alone would offer Safari
        // for removal and measure it as 0 bytes.
        let resolved = unique.map { $0.url.resolvingSymlinksInPath() }
        // Measured four at a time. Walking every file of every bundle one
        // after another was most of the three seconds the Apps list took
        // to appear at each launch. Each size is still read fresh; nothing
        // is remembered between launches. Only cancellation stops it, and
        // a cancelled read has nothing to publish.
        guard let sizes = try? await BoundedTasks.map(resolved, limit: 4, operation: { Self.size(of: $0) }) else {
            return []
        }

        for (index, candidate) in unique.enumerated() {
            let (bundleURL, protected, host) = (candidate.url, candidate.protected, candidate.host)
            let identity = await resolver.resolve(bundleURL: bundleURL)
            var application = InstalledApplication(
                identity: identity,
                url: bundleURL,
                bundleSizeBytes: sizes[index],
                isSystemProtected: protected || Self.isOSOwned(resolved[index])
            )
            application.enclosingApp = host
            describe(&application, resolved: resolved[index], casks: casks, developers: &developers)
            results.append(application)
        }

        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Category, source, developer and use, for grouping. Every value is
    /// read from a file or Spotlight; none of it is worked out by guessing.
    private func describe(
        _ application: inout InstalledApplication, resolved: URL, casks: HomebrewCaskInventory,
        developers: inout DeveloperNames
    ) {
        let bundleID = application.identity.bundleID
        application.category = Self.infoValue("LSApplicationCategoryType", in: resolved)
        application.source = ApplicationFacts.source(
            bundleID: bundleID, path: resolved.path,
            hasAppStoreReceipt: FileManager.default.fileExists(
                atPath: resolved.appendingPathComponent("Contents/_MASReceipt/receipt").path
            ),
            isHomebrewCask: UpdateSourceScanner.matchingCask(for: application, among: casks) != nil
        )
        application.developer = ApplicationFacts.isApple(bundleID: bundleID)
            ? "Apple"
            : developers.name(team: application.identity.teamID, bundle: resolved)
            ?? ApplicationFacts.vendor(fromBundleID: bundleID)
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, resolved as CFURL) {
            application.lastOpened = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            application.addedAt = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
        }
    }

    private static func infoValue(_ key: String, in bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return values[key] as? String
    }

    /// An application to describe, with whether it can be removed on its
    /// own and the app it ships inside, if any.
    struct Candidate {
        let url: URL
        let protected: Bool
        let host: String?
    }

    /// Every application to describe, with whether it can be removed on its
    /// own and the app it ships inside, if any.
    ///
    /// The folders are walked first, as before. Then two additions, because
    /// the walk alone missed applications people use: an app's own
    /// `Contents/Applications` (Icon Composer, Instruments, FileMerge and
    /// Simulator all live inside Xcode), and whatever Spotlight has indexed
    /// as an application anywhere under the same folders, which catches an
    /// app more than one folder deep. Spotlight adds; it never removes, so
    /// a Mac with indexing off still gets the full walk.
    private func candidates() -> [Candidate] {
        var found: [Candidate] = []
        for domain in searchDomains {
            for bundle in bundles(in: domain.url) {
                found.append(Candidate(url: bundle, protected: domain.protected, host: nil))
                let host = Self.name(of: bundle)
                // It stands where its host stands: removable when the host
                // is yours, protected when the host belongs to macOS.
                let hostProtected = domain.protected || Self.isOSOwned(bundle.resolvingSymlinksInPath())
                found.append(contentsOf: Self.embeddedApplications(in: bundle).map {
                    Candidate(url: $0, protected: hostProtected, host: host)
                })
            }
        }
        // Spotlight answers only about the real disk, not a test fixture.
        if root.rootURL.path == "/" {
            let known = Set(found.map(\.url.standardizedFileURL.path))
            let indexed = Self.indexedApplications(in: searchDomains.map(\.url))
            for url in indexed where !known.contains(url.standardizedFileURL.path) {
                guard let placement = Self.placement(of: url) else { continue }
                let host: String? = placement
                let protected = searchDomains.contains { $0.protected && url.path.hasPrefix($0.url.path + "/") }
                found.append(
                    Candidate(url: url, protected: protected, host: host)
                )
            }
        }
        found += packagedElsewhere().map { Candidate(url: $0, protected: false, host: nil) }
        return found
    }

    /// Applications an installer package put outside the Applications
    /// folders, straight into its own folder in `/Library`.
    ///
    /// Microsoft AutoUpdate arrives with Teams in
    /// `/Library/Application Support/Microsoft/MAU2.0`. It runs, it launches
    /// itself at login, and it outlived Teams on this Mac, yet no list in
    /// Brim showed it, so there was nothing to remove it from. The rule is
    /// the helper's (`HelperScope.installFolder`), so whatever is listed
    /// here is something Brim can also take away.
    private func packagedElsewhere() -> [URL] {
        InstalledBundleInventory.packageInstallFolders(in: root).flatMap { directory in
            Self.entries(of: directory).filter { ($0 as NSString).pathExtension == "app" }
                .map { directory.appendingPathComponent($0) }
        }
    }

    /// Apps an application carries for people to open, in the one place
    /// macOS looks for them: `Contents/Applications`. Helpers buried in
    /// `Frameworks` or `Library` are machinery, not apps anyone launches.
    static func embeddedApplications(in bundle: URL) -> [URL] {
        let folder = bundle.appendingPathComponent("Contents/Applications")
        return entries(of: folder).filter { ($0 as NSString).pathExtension == "app" }
            .map { folder.appendingPathComponent($0) }
    }

    /// Where Spotlight's answer sits. Nil for an app inside another bundle
    /// anywhere but its `Contents/Applications`, which is a helper. The
    /// outer optional is whether to list it at all, the inner the host.
    static func placement(of url: URL) -> String?? {
        let components = url.deletingLastPathComponent().pathComponents
        guard let hostIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else {
            return .some(nil)
        }
        let rest = Array(components[(hostIndex + 1)...])
        guard rest == ["Contents", "Applications"] else { return nil }
        return .some((components[hostIndex] as NSString).deletingPathExtension)
    }

    /// Every application bundle Spotlight knows of under these folders,
    /// through the public Metadata API. Empty when indexing is off.
    static func indexedApplications(in scopes: [URL]) -> [URL] {
        let predicate = "kMDItemContentType == 'com.apple.application-bundle'" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, scopes.map(\.path) as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        return (0 ..< MDQueryGetResultCount(query)).compactMap { index in
            guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            return (MDItemCopyAttribute(item, kMDItemPath) as? String).map { URL(fileURLWithPath: $0) }
        }
    }

    private static func name(of bundle: URL) -> String {
        bundle.deletingPathExtension().lastPathComponent
    }

    /// Top-level `.app` bundles, and one folder down so
    /// `/Applications/Utilities` is included.
    private func bundles(in directory: URL) -> [URL] {
        var found: [URL] = []
        for name in Self.entries(of: directory) {
            let entry = directory.appendingPathComponent(name)
            if entry.pathExtension == "app" {
                found.append(entry)
            } else if Self.isDirectory(entry) {
                found.append(contentsOf: Self.entries(of: entry)
                    .filter { ($0 as NSString).pathExtension == "app" }
                    .map { entry.appendingPathComponent($0) })
            }
        }
        return found
    }

    /// Raw directory entries by path.
    ///
    /// Deliberately the string API rather than `contentsOfDirectory(at:)`:
    /// the URL variant omits symlinks it cannot resolve, and on current macOS
    /// `/Applications/Safari.app` is a symlink into a Cryptex. The URL API
    /// leaves Safari out of the listing entirely, which for an uninstaller
    /// means silently not knowing about an installed application.
    private static func entries(of directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
    }

    /// Follows symlinks on purpose: a symlinked `.app` is still an app, and a
    /// symlinked folder such as `Utilities` still holds apps worth listing.
    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Locations macOS owns and protects, where an uninstall cannot succeed
    /// however the bundle is reached. Checked against the resolved path, so a
    /// symlink from a writable directory cannot disguise a system app.
    private static func isOSOwned(_ resolved: URL) -> Bool {
        let protectedRoots = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
        return protectedRoots.contains { resolved.path.hasPrefix($0) }
    }

    /// The bundle's logical size, every file and link counted by `lstat`,
    /// the figure Finder shows.
    ///
    /// A plain `fts` walk rather than `FileManager`'s enumerator, which built
    /// a URL and read resource values for every file: the same totals, in
    /// half the time or less. Xcode alone took 1.2 seconds that way and
    /// 0.8 this way. Links are not followed.
    static func size(of url: URL) -> Int64 {
        var total: Int64 = 0
        url.path.withCString { path in
            guard let copy = strdup(path) else { return }
            defer { free(copy) }
            var roots: [UnsafeMutablePointer<CChar>?] = [copy, nil]
            guard let walk = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
            defer { fts_close(walk) }
            while let entry = fts_read(walk) {
                // The root itself is the bundle folder, never a file to count.
                guard entry.pointee.fts_level > 0 else { continue }
                switch Int32(entry.pointee.fts_info) {
                case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                    if let status = entry.pointee.fts_statp {
                        total += Int64(status.pointee.st_size)
                    }
                default:
                    break
                }
            }
        }
        return total
    }
}

/// Organisation names by signing team, read from the certificate once per
/// team rather than once per app: Adobe's five apps cost one read.
struct DeveloperNames {
    private var byTeam: [String: String] = [:]

    mutating func name(team: String?, bundle: URL) -> String? {
        guard let team else { return nil }
        if let known = byTeam[team] {
            return known
        }
        // Not remembered when nothing is found: an App Store app is
        // re-signed by Apple and names nobody, and another app from the
        // same team may still say who it is.
        guard let found = Self.certificateOrganisation(of: bundle) else { return nil }
        byTeam[team] = found
        return found
    }

    private static func certificateOrganisation(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            == errSecSuccess,
            let values = information as? [String: Any],
            let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first,
            let summary = SecCertificateCopySubjectSummary(leaf) as String?
        else { return nil }
        return ApplicationFacts.organisation(fromCertificateSummary: summary)
    }
}
