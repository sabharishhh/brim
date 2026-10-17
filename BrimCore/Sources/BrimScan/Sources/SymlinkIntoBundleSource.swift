import BrimCore
import Foundation

/// A command that is really a link into an application bundle, such as
/// `/usr/local/bin/code` into Visual Studio Code. Not a `LocationInventory`
/// rule, where `/usr/local/bin` is floored to Tier C: a link names the bundle
/// outright, so following it is proof and earns Tier B. Only the link is
/// evidence; what it points at goes with the bundle.
public struct SymlinkIntoBundleSource: EvidenceSource {
    /// Where a command installed beside an application tends to go. Listed one
    /// level deep, not walked.
    static let linkDomains: [FileSystemRoot.Domain] = [
        .usrLocalBin, .usrLocalSbin, .userDotLocalBin
    ]

    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        let fm = FileManager.default

        // The bundles this application could be, resolved so a link through
        // `/private` or a relative hop still compares equal.
        let bundles = Self.verifiedBundleLocations(for: identity, in: root)
            .filter { fm.fileExists(atPath: $0.path) }
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        guard !bundles.isEmpty else { return EvidenceFindings(evidence: []) }

        var results: [Evidence] = []
        var unreadable: [String] = []
        for domain in Self.linkDomains {
            let directory = root.url(for: domain)
            let names: [String]
            switch DirectoryEntries.read(directory) {
            case .absent: continue
            case .refused:
                unreadable.append(directory.path)
                continue
            case let .listed(listed): names = listed
            }
            for name in names {
                let link = directory.appendingPathComponent(name)
                guard let target = Self.target(of: link, fm: fm) else { continue }
                guard bundles.contains(where: { target == $0 || target.hasPrefix($0 + "/") })
                else { continue }
                results.append(Evidence(
                    url: link,
                    tier: .B,
                    mechanism: "SymlinkIntoBundleSource",
                    humanSentence: "A command that is a link into this application. Removing "
                        + "the application without it leaves a command that cannot run."
                ))
            }
        }
        return EvidenceFindings(evidence: results, completeness: ScanCompleteness(unreadable: unreadable))
    }

    /// Where this application's bundle could be: its file name, in
    /// `/Applications` and `~/Applications`, as `AppBundleSource` claims it. The
    /// file name only: `CFBundleName` says what an app calls itself, not where
    /// its bundle is, and a different `Code.app` would have been claimed for
    /// Visual Studio Code. `LaunchdSource` asks here too.
    public static func bundleLocations(for identity: Identity, in root: FileSystemRoot) -> [URL] {
        // A selected installation is authoritative; looking up its name again
        // could add another copy with the same identifier.
        if let path = identity.bundlePath {
            return [URL(fileURLWithPath: path)]
        }
        let userApplications = root.url(for: .userLibrary)
            .deletingLastPathComponent()
            .appendingPathComponent("Applications")
        return [
            root.url(for: .applications).appendingPathComponent("\(identity.name).app"),
            userApplications.appendingPathComponent("\(identity.name).app")
        ]
    }

    public static func verifiedBundleLocations(for identity: Identity, in root: FileSystemRoot) -> [URL] {
        guard let bundleID = identity.bundleID else { return [] }
        return bundleLocations(for: identity, in: root).filter { url in
            Bundle(url: url)?.bundleIdentifier == bundleID
        }
    }

    /// Where a link lands, relative hops and all, or nil when the path is not a
    /// link. `resolvingSymlinksInPath` alone would treat every plain binary as a
    /// link to itself.
    static func target(of link: URL, fm: FileManager) -> String? {
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
            return nil
        }
        let resolved = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : link.deletingLastPathComponent().appendingPathComponent(destination)
        return resolved.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
