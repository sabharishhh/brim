import Foundation
import BrimCore

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
        self.resolver = IdentityResolver(root: root)
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

        for domain in searchDomains {
            for bundleURL in bundles(in: domain.url) {
                // A bundle reachable from two domains is one application.
                guard seen.insert(bundleURL.standardizedFileURL.path).inserted else { continue }

                let identity = await resolver.resolve(bundleURL: bundleURL)
                // Judge protection and size by where the bundle actually is,
                // not by where it is listed: /Applications/Safari.app is a
                // symlink into a Cryptex, so a check on the listed path alone
                // would offer Safari for removal and measure it as 0 bytes.
                let resolved = bundleURL.resolvingSymlinksInPath()
                results.append(InstalledApplication(
                    identity: identity,
                    url: bundleURL,
                    bundleSizeBytes: Self.size(of: resolved),
                    isSystemProtected: domain.protected || Self.isOSOwned(resolved)
                ))
            }
        }

        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Top-level `.app` bundles only. Applications nested inside another app's
    /// bundle belong to that app's footprint, not to this inventory, and
    /// `/Applications/Utilities` is one level down so it is included.
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

    private static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0)
        }
        return total
    }
}
