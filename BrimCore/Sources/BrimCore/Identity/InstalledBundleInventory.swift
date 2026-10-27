import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// Installed bundles in application directories, including vendor subfolders.
/// Stops at bundles; their embedded code is read by BundleSurfaceReader.
public struct InstalledBundleInventory: Sendable {
    public let bundles: [URL]
    public let completeness: ScanCompleteness
    private let root: FileSystemRoot

    /// Broken executable wrappers remain discoverable for cleanup, but cannot
    /// protect another app's files as a usable installation.
    public var claimingBundles: [URL] {
        bundles.filter { !ApplicationBundle.hasMissingLinkedExecutable($0, in: root) }
    }

    public static func read(
        in root: FileSystemRoot, including identifiers: [String] = [], knownLocations: [URL] = [],
        lookup: ((String) throws -> [URL])? = nil
    ) -> Self {
        var reader = Reader(root: root)
        var directories = [root.url(for: .applications), root.url(for: .userApplications),
                           root.rootURL.appendingPathComponent("System/Applications")]
        for user in reader.entries(root.url(for: .users)) {
            directories.append(user.appendingPathComponent("Applications"))
        }
        for volume in reader.entries(root.url(for: .volumes)) {
            directories.append(volume.appendingPathComponent("Applications"))
            directories.append(volume.appendingPathComponent("Users/\(root.userName)/Applications"))
        }
        let scan = ApplicationDirectoryScan.read(in: directories, boundary: root.rootURL, budget: reader.budget)
        reader.bundles += scan.bundles
        reader.unreadable.formUnion(scan.completeness.unreadable)
        reader.timedOut.formUnion(scan.completeness.timedOut)
        // Applications a package put beside the Applications folders, the same
        // ones the Apps list shows, so their folders are never offered as
        // leftovers while they run.
        for folder in packageInstallFolders(in: root) {
            reader.bundles += reader.entries(folder).filter { $0.pathExtension.lowercased() == "app" }
        }
        var candidates = knownLocations
        if let query = lookup {
            for identifier in Set(identifiers).sorted() {
                do {
                    candidates += try query(identifier)
                } catch {
                    reader.unreadable.insert("Launch Services: \(identifier)")
                }
            }
        }
        reader.consider(candidates, matching: identifiers)
        let unique = reader.uniqueBundles()
        return Self(bundles: unique.sorted { $0.path < $1.path },
                    completeness: ScanCompleteness(unreadable: Array(reader.unreadable),
                                                   timedOut: Array(reader.timedOut)), root: root)
    }

    /// Folders under `/Library` a non-Apple package installed into, read from
    /// its receipt and held to administrator cleanup's rule, so anything found
    /// there can also be removed.
    public static func packageInstallFolders(in root: FileSystemRoot) -> [URL] {
        let receipts = root.url(for: .systemReceipts)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: receipts.path)) ?? []
        var folders: [URL] = []
        for file in names.sorted()
            where file.hasSuffix(".plist") && !file.hasPrefix(".") && !file.lowercased().hasPrefix("com.apple.") {
            guard let plist = NSDictionary(contentsOf: receipts.appendingPathComponent(file)),
                  let prefix = plist["InstallPrefixPath"] as? String,
                  let folder = HelperScope.installFolder(prefix: prefix)
            else { continue }
            let url = root.rootURL.appendingPathComponent(String(folder.dropFirst()))
            if !folders.contains(url) {
                folders.append(url)
            }
        }
        return folders
    }

    private struct Reader {
        let root: FileSystemRoot
        let budget = ScanBudget(total: 5)
        var bundles: [URL] = []
        var unreadable = Set<String>()
        var timedOut = Set<String>()

        mutating func consider(_ candidates: [URL], matching identifiers: [String]) {
            let wanted = Set(identifiers.map { $0.lowercased() })
            for candidate in candidates {
                let path = candidate.resolvingSymlinksInPath().path
                let boundary = root.rootURL.resolvingSymlinksInPath().path
                guard boundary == "/" || path == boundary || path.hasPrefix(boundary + "/") else {
                    unreadable.insert(candidate.path)
                    continue
                }
                let presence = PathObservation.observe(candidate.path)
                if presence.isUnknown {
                    unreadable.insert(candidate.path); continue
                }
                guard presence.isPresent else { continue }
                let metadata = candidate.appendingPathComponent("Contents/Info.plist")
                guard let contents = NSDictionary(contentsOf: metadata),
                      let identifier = contents["CFBundleIdentifier"] as? String
                else {
                    unreadable.insert(candidate.path)
                    continue
                }
                if wanted.isEmpty || wanted.contains(identifier.lowercased()) {
                    bundles.append(candidate)
                }
            }
        }

        mutating func uniqueBundles() -> [URL] {
            var seen = Set<String>()
            return bundles.filter { url in
                var information = stat()
                guard stat(url.path, &information) == 0 else {
                    unreadable.insert(url.path)
                    return false
                }
                return seen.insert("\(information.st_dev):\(information.st_ino)").inserted
            }
        }

        mutating func entries(_ directory: URL) -> [URL] {
            guard !budget.hasRunOut else { timedOut.insert(directory.path); return [] }
            do {
                return try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                    options: [.skipsHiddenFiles]
                ).sorted { $0.path < $1.path }
            } catch {
                let failure = error as NSError
                let cocoaMissing = failure.domain == NSCocoaErrorDomain
                    && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
                let posixMissing = failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT)
                if !cocoaMissing, !posixMissing {
                    unreadable.insert(directory.path)
                }
                return []
            }
        }
    }
}
