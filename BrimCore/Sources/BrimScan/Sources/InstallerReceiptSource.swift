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
            var named = Self.namedPackages(for: identity)
            if case let .listed(names) = listing, let installer = installerOf(identity, among: names, in: receiptsDir, root: root),
               !named.contains(where: { $0.0 == installer }) {
                named.insert((installer, .A), at: 0)
            }
            for (packageID, tier) in named {
                let bomURL = receiptsDir.appendingPathComponent("\(packageID).bom")
                guard FileManager.default.fileExists(atPath: bomURL.path),
                      !results.contains(where: { $0.url == bomURL }) else { continue }
                results.append(Evidence(
                    url: bomURL, tier: tier, mechanism: "InstallerReceiptSource",
                    humanSentence: packageID == identity.bundleID
                        ? "Installer receipt matching bundle identifier"
                        : "Installer receipt for this app"
                ))
                if tier == .A { anchors.append(packageID) }
            }
            guard case let .listed(names) = listing else { continue }
            results += sameRun(as: anchors, among: names, in: receiptsDir, identity: identity, root: root)
                .filter { found in !results.contains(where: { $0.url == found.url }) }
        }
        return EvidenceFindings(evidence: results, completeness: ScanCompleteness(unreadable: unreadable))
    }

    /// The package that installed this bundle, found by where it put it:
    /// Microsoft AutoUpdate's package is
    /// `com.microsoft.package.Microsoft_AutoUpdate.app`, which neither its
    /// identifier nor its name would find. Only receipts whose install
    /// folder holds the bundle are asked what they installed.
    private func installerOf(
        _ identity: Identity, among names: [String], in receiptsDir: URL, root: FileSystemRoot
    ) -> String? {
        guard let bundlePath = identity.bundlePath else { return nil }
        let bundle = URL(fileURLWithPath: bundlePath).standardizedFileURL
        let folder = bundle.deletingLastPathComponent().path
        for name in names where name.hasSuffix(".plist") && !name.hasPrefix("com.apple.") {
            let packageID = String(name.dropLast(".plist".count))
            guard let receipt = Self.receipt(receiptsDir, packageID),
                  root.rootURL.appendingPathComponent(receipt.prefix).standardizedFileURL.path == folder,
                  payload(packageID, receiptsDir)?.contains(bundle.lastPathComponent) == true
            else { continue }
            return packageID
        }
        return nil
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
            // installer, is that application's to remove. Only an
            // application installed where applications go is another
            // application: Teams' installer also put Microsoft AutoUpdate
            // in `Library/Application Support`, and reading every `.app` as
            // a second product left it and its caches behind after Teams
            // was removed.
            guard !installed.contains(where: {
                $0.pathExtension == "app" && $0.resolvingSymlinksInPath().path != subject
                    && Self.isInApplicationsFolder($0, root: root)
            }) else { continue }
            // A helper application the developer's other packages also
            // install stays while one of them is still here: AutoUpdate
            // serves Word as much as it served Teams.
            if installed.contains(where: { $0.pathExtension == "app" }),
               stillServes(packageID, besides: tokens, among: names, in: receiptsDir, root: root) {
                continue
            }
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

    /// Whether a package from the same developer, installed by another run,
    /// put down an application that is still installed.
    private func stillServes(
        _ packageID: String, besides tokens: Set<String>, among names: [String],
        in receiptsDir: URL, root: FileSystemRoot
    ) -> Bool {
        let vendor = Self.vendor(of: packageID)
        for name in names where name.hasSuffix(".plist") {
            let other = String(name.dropLast(".plist".count))
            guard other != packageID, Self.vendor(of: other) == vendor,
                  let receipt = Self.receipt(receiptsDir, other),
                  !(receipt.token.map(tokens.contains) ?? false),
                  let items = payload(other, receiptsDir)
            else { continue }
            let prefix = root.rootURL.appendingPathComponent(receipt.prefix)
            if items.contains(where: { item in
                let url = prefix.appendingPathComponent(item)
                return url.pathExtension == "app" && Self.isInApplicationsFolder(url, root: root)
                    && FileManager.default.fileExists(atPath: url.path)
            }) { return true }
        }
        return false
    }

    /// The first two labels, the developer's namespace.
    static func vendor(of packageID: String) -> String {
        packageID.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// `/Applications`, or a person's own `~/Applications`, and anything
    /// in folders under either.
    static func isInApplicationsFolder(_ url: URL, root: FileSystemRoot) -> Bool {
        let rootParts = root.rootURL.standardizedFileURL.pathComponents
        let parts = Array(url.standardizedFileURL.pathComponents.dropFirst(rootParts.count))
        if parts.first == "Applications" { return true }
        return parts.count > 3 && parts[0] == "Users" && parts[2] == "Applications"
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
