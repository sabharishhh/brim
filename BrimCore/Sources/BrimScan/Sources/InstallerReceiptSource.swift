import BrimCore
import Foundation

/// Resolves installer receipts and Bill of Materials (BOM) files (Tier A).
public struct InstallerReceiptSource: EvidenceSource {
    public init() {}

    public func evidence(for identity: Identity, in root: FileSystemRoot) async throws -> [Evidence] {
        await scan(for: identity, in: root).evidence
    }

    public func scan(for identity: Identity, in root: FileSystemRoot) async -> EvidenceFindings {
        var results = [Evidence]()

        let fm = FileManager.default
        let receiptsDir = root.url(for: .receipts)
        let hasIdentifiers = identity.packageIdentifier != nil || !identity.searchBundleIdentifiers.isEmpty
        let unreadable = hasIdentifiers && DirectoryEntries.read(receiptsDir).isRefused
            ? [receiptsDir.path] : []

        // If we know the package identifier from the identity
        if let pkgId = identity.packageIdentifier {
            let bomURL = receiptsDir.appendingPathComponent("\(pkgId).bom")
            if fm.fileExists(atPath: bomURL.path) {
                results.append(Evidence(
                    url: bomURL,
                    tier: .A,
                    mechanism: "InstallerReceiptSource",
                    humanSentence: "Installer receipt matching package identifier"
                ))
            }
        }

        // If we know the bundleID, it might also have a receipt
        for bundleID in identity.searchBundleIdentifiers {
            let bomURL = receiptsDir.appendingPathComponent("\(bundleID).bom")
            if fm.fileExists(atPath: bomURL.path), !results.contains(where: { $0.url == bomURL }) {
                results.append(Evidence(
                    url: bomURL,
                    tier: bundleID == identity.bundleID ? .A : .C,
                    mechanism: "InstallerReceiptSource",
                    humanSentence: "Installer receipt matching bundle identifier"
                ))
            }
        }

        return EvidenceFindings(evidence: results, completeness: ScanCompleteness(unreadable: unreadable))
    }
}
