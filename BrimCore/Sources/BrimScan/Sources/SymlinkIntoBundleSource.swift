import BrimCore
import Foundation

/// A command on the path that is really a link into an application bundle.
///
/// The leftovers sweep already reads links the other way round: a link whose
/// target has gone is dangling, and a dangling link is residue. Run forwards,
/// the same fact answers a question the uninstall path could not: Visual
/// Studio Code installs `/usr/local/bin/code` pointing at
/// `/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`,
/// and removing the application without the link is how a Mac ends up with a
/// `code` command that reports "no such file or directory".
///
/// This is deliberately not a rule in `LocationInventory`. Everything in
/// `/usr/local/bin` is floored to Tier C there, and rightly: the only thing
/// tying a bare binary to an application is a shared name, and two products
/// called Studio is ordinary. A symbolic link is not a shared name. It names
/// the bundle outright, and following it is proof rather than inference, so
/// it earns Tier B on its own evidence.
///
/// Only the link is ever evidence. What a link points at inside the bundle
/// goes when the bundle goes, and a link pointing somewhere else entirely is
/// somebody else's.
public struct SymlinkIntoBundleSource: EvidenceSource {
    /// Where a command installed beside an application tends to be put. Each
    /// is listed rather than walked, one level deep: these directories hold
    /// commands, not trees, and a recursive walk of `/usr/local` on a
    /// developer's Mac is its own kind of mistake.
    static let linkDomains: [FileSystemRoot.Domain] = [
        .usrLocalBin, .usrLocalSbin, .userDotLocalBin
    ]

    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        let fm = FileManager.default

        // The bundles this application could be. Resolved so a link through
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

    /// Where this application's bundle could be sitting: its file name, in
    /// the Applications folder and in the one inside the home folder, which
    /// is exactly what `AppBundleSource` claims as the application itself.
    ///
    /// **The file name only.** This used to look under every name in
    /// `searchNames`, which includes `CFBundleName`, and `CFBundleName` says
    /// what an application calls itself, not where its bundle lives. Visual
    /// Studio Code calls itself "Code", so with an unrelated application
    /// called `Code.app` installed, every command linked into that other
    /// application was claimed for Visual Studio Code at Tier B and would have
    /// been trashed with it. The name that finds support folders is the wrong
    /// one for finding bundles.
    ///
    /// Also the one place `LaunchdSource` asks, so a link and a launchd job
    /// are proven by pointing into the same bundles.
    public static func bundleLocations(for identity: Identity, in root: FileSystemRoot) -> [URL] {
        let userApplications = root.url(for: .userLibrary)
            .deletingLastPathComponent()
            .appendingPathComponent("Applications")
        return (identity.bundlePath.map { [URL(fileURLWithPath: $0)] } ?? []) + [
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

    /// Where a link actually lands, relative hops and all, or nil when the
    /// path is not a link at all.
    ///
    /// Read with `lstat` semantics on purpose. `resolvingSymlinksInPath` on a
    /// plain file returns the file, so using it alone would treat every
    /// binary in the directory as a link to itself.
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
