import BrimCore
import Foundation

/// Resolves installer receipts and Bill of Materials (BOM) files (Tier A),
/// and whatever else the same installer run put down (Tier B).
///
/// **Receipts live in `/private/var/db/receipts`.** This source only ever
/// looked in `/Library/Receipts`, which a modern Mac leaves empty, so no
/// receipt was found for any application and `forgetReceipt` was never
/// planned. Every product installed from a package kept showing up in
/// `pkgutil --pkgs` after Brim removed it. Both are read, because older
/// installers and the test fixtures still use the old place.
///
/// **One installer run can install several packages**, and only one of them
/// is named after the application. Microsoft Teams' installer also puts an
/// audio driver in `/Library/Audio/Plug-Ins/HAL` under a package called
/// `com.microsoft.MSTeamsAudioDevice`, and nothing about that name or the
/// driver's identifier says Teams. What does is the receipt: every package
/// of one run carries the same `InstallToken`. So a package sharing the
/// application's token is part of the application, and so is what it
/// installed, as long as that is not another application.
public struct InstallerReceiptSource: EvidenceSource {
    /// The top-level items a package installed, relative to its prefix.
    /// Nil when they cannot be read.
    public typealias PayloadReader = @Sendable (_ packageID: String, _ receipts: URL) -> [String]?

    private let payload: PayloadReader

    public init(payload: @escaping PayloadReader = InstallerReceiptSource.systemPayload) {
        self.payload = payload
    }

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        var results = [Evidence]()
        var unreadable: [String] = []
        let hasIdentifiers = identity.packageIdentifier != nil || !identity.searchBundleIdentifiers.isEmpty
        guard hasIdentifiers else { return EvidenceFindings(evidence: []) }

        for receiptsDir in [root.url(for: .systemReceipts), root.url(for: .receipts)] {
            let listing = DirectoryEntries.read(receiptsDir)
            if listing.isRefused {
                unreadable.append(receiptsDir.path)
                continue
            }
            var anchors: [String] = []
            for (packageID, tier) in Self.namedPackages(for: identity) {
                let bomURL = receiptsDir.appendingPathComponent("\(packageID).bom")
                guard FileManager.default.fileExists(atPath: bomURL.path),
                      !results.contains(where: { $0.url == bomURL }) else { continue }
                results.append(Evidence(
                    url: bomURL, tier: tier, mechanism: "InstallerReceiptSource",
                    humanSentence: packageID == identity.packageIdentifier
                        ? "Installer receipt matching package identifier"
                        : "Installer receipt matching bundle identifier"
                ))
                if tier == .A { anchors.append(packageID) }
            }
            guard case let .listed(names) = listing else { continue }
            results += sameRun(as: anchors, among: names, in: receiptsDir, identity: identity, root: root)
                .filter { found in !results.contains(where: { $0.url == found.url }) }
        }
        return EvidenceFindings(evidence: results, completeness: ScanCompleteness(unreadable: unreadable))
    }

    /// Packages named after the application, and how sure each name is.
    static func namedPackages(for identity: Identity) -> [(String, EvidenceTier)] {
        var named: [(String, EvidenceTier)] = []
        if let pkgID = identity.packageIdentifier { named.append((pkgID, .A)) }
        for bundleID in identity.searchBundleIdentifiers where !named.contains(where: { $0.0 == bundleID }) {
            named.append((bundleID, bundleID == identity.bundleID ? .A : .C))
        }
        return named
    }

    /// Receipts, and what they installed, from the run that installed the
    /// application.
    private func sameRun(
        as anchors: [String], among names: [String], in receiptsDir: URL,
        identity: Identity, root: FileSystemRoot
    ) -> [Evidence] {
        let tokens = Set(anchors.compactMap { Self.receipt(receiptsDir, $0)?.token })
        guard !tokens.isEmpty else { return [] }
        let subject = identity.bundlePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        var found: [Evidence] = []
        for name in names where name.hasSuffix(".plist") {
            let packageID = String(name.dropLast(".plist".count))
            guard !anchors.contains(packageID), !packageID.hasPrefix("com.apple."),
                  let receipt = Self.receipt(receiptsDir, packageID),
                  let token = receipt.token, tokens.contains(token),
                  let items = payload(packageID, receiptsDir)
            else { continue }
            let prefix = root.rootURL.appendingPathComponent(receipt.prefix)
            let installed = items.map { prefix.appendingPathComponent($0) }
            // Another application's package, installed alongside by a suite
            // installer, is that application's to remove.
            guard !installed.contains(where: {
                $0.pathExtension == "app" && $0.resolvingSymlinksInPath().path != subject
            }) else { continue }
            let sentence = "Installed in the same run as \(identity.name), by the same installer."
            let bomURL = receiptsDir.appendingPathComponent("\(packageID).bom")
            if FileManager.default.fileExists(atPath: bomURL.path) {
                found.append(Evidence(url: bomURL, tier: .B, mechanism: "InstallerReceiptSource",
                                      humanSentence: sentence))
            }
            for url in installed where Self.isOwnItem(url, root: root)
                && FileManager.default.fileExists(atPath: url.path) {
                found.append(Evidence(url: url, tier: .B, mechanism: "InstallerPayloadSource",
                                      humanSentence: sentence))
            }
        }
        return found
    }

    /// A payload's top level can be a shared folder when a package installs
    /// with a shallow prefix. Only something that is plainly one item, a
    /// bundle or a path at least three folders deep, is taken.
    static func isOwnItem(_ url: URL, root: FileSystemRoot) -> Bool {
        let rootDepth = root.rootURL.standardizedFileURL.pathComponents.count
        let depth = url.standardizedFileURL.pathComponents.count - rootDepth
        return !url.pathExtension.isEmpty || depth >= 4
    }

    static func receipt(_ receiptsDir: URL, _ packageID: String) -> (token: String?, prefix: String)? {
        let url = receiptsDir.appendingPathComponent("\(packageID).plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return (plist["InstallToken"] as? String, plist["InstallPrefixPath"] as? String ?? "")
    }

    /// Asks `pkgutil`, which reads the BOM format, and only about the real
    /// receipts folder: a fixture's receipts describe no real package.
    public static let systemPayload: PayloadReader = { packageID, receipts in
        // `resolvingSymlinksInPath` drops `/private`, so both spellings.
        guard ["/private/var/db/receipts", "/var/db/receipts"].contains(receipts.standardizedFileURL.path),
              let listing = ToolOutput.read("/usr/sbin/pkgutil", ["--files", packageID])
        else { return nil }
        return listing.split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty && !$0.contains("/") && $0 != "." }
    }
}
