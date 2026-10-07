import BrimCore
import BrimPrivileged
import BrimProtocol
import BrimScan
import Foundation

/// Connects approved protected operations to a temporary administrator process.
/// Availability and normal scans never request authentication.
@MainActor
public enum HelperRoute {
    /// The one helper client, kept so a review can ask about it.
    private static var connected: PrivilegedHelperClient?

    public static func connect(_ helper: PrivilegedHelperClient, to service: any BrimServiceProtocol) async {
        connected = helper
        await service.usePrivilegedBatch(begin: { await helper.beginBatch() },
                                         end: { await helper.endBatch() })
        await service.usePrivilegedRemover { path in
            await remove(path, helper: helper)
        }
        await service.usePrivilegedReceiptForgetter { packageID in
            if let problem = await ready(helper) {
                return problem
            }
            return await helper.forgetReceipt(packageID: packageID)
        }
        await service.useRecoveryVerifier {
            try await helper.freshRecoveryItems().map {
                RecoveryCopy(path: $0.path, name: $0.name, bundleID: $0.bundleID,
                             sizeBytes: $0.sizeBytes, sizeIsKnown: $0.sizeIsKnown,
                             fingerprint: TargetFingerprint(dev: $0.dev, ino: $0.ino, mtime: $0.mtime))
            }
        }
        await service.useRecoveryCopies(reader: {
            if let problem = await ready(helper) {
                throw NSError(domain: "BrimRecovery", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: problem])
            }
            return try await helper.listRecoveryItems().map {
                RecoveryCopy(path: $0.path, name: $0.name, bundleID: $0.bundleID,
                             sizeBytes: $0.sizeBytes, sizeIsKnown: $0.sizeIsKnown,
                             fingerprint: TargetFingerprint(dev: $0.dev, ino: $0.ino, mtime: $0.mtime))
            }
        }, remover: { path, fingerprint in
            if let problem = await ready(helper) {
                return problem
            }
            guard let identifier = RecoveryCopy.identifier(for: path) else {
                return "That is not an individual recovery copy."
            }
            return await helper.removeRecoveryItem(identifier: identifier,
                                                   expectedDevice: fingerprint.dev,
                                                   expectedInode: fingerprint.ino)
        })
    }

    /// Sends a path to whichever of the helper's operations covers its
    /// folder. The folders are the helper's own; see `HelperScope`, which
    /// is the planner's reading of the same lists.
    static func remove(_ path: String, helper: PrivilegedHelperClient) async -> String? {
        if let problem = await ready(helper) {
            return problem
        }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if let domain = PrivilegedJobRemoval.Domain.allCases.first(where: { $0.directory == folder }) {
            return await helper.removeDefunctJob(domain: domain, name: name)
        }
        if let domain = PrivilegedLinkRemoval.Domain.allCases.first(where: { $0.directory == folder }) {
            return await helper.removeBrokenCommand(domain: domain, name: name)
        }
        if let domain = PrivilegedBundleRemoval.Domain.allCases.first(where: { $0.directory == folder }) {
            return await helper.removeInstalledBundle(domain: domain, name: name)
        }
        if folder == PrivilegedCacheRemoval.directory {
            return await helper.removeSystemCache(name: name)
        }
        if folder == PrivilegedPreferenceRemoval.directory {
            return await helper.removeSystemPreference(name: name)
        }
        if let packageID = PrivilegedPayloadRemoval.package(for: path) {
            return await helper.removeInstalledPayload(packageID: packageID, name: name)
        }
        return "Administrator cleanup does not remove things from \(folder)."
    }

    /// Nil when the helper can take work. Asked by a review that is about
    /// to hand it some, which is the moment the answer is needed.
    public static func problem() async -> String? {
        guard let connected else { return "Administrator cleanup is unavailable in this window." }
        return await ready(connected)
    }

    /// Explicitly reads protected recovery copies, then stops the process.
    public static func authorizeRecoveryRead() async -> String? {
        guard let connected else { return "Administrator cleanup is unavailable in this window." }
        return await connected.authorizeRecoveryRead()
    }

    private static func ready(_ helper: PrivilegedHelperClient) async -> String? {
        helper.refresh()
        return helper.state == .ready ? nil : "Administrator cleanup is unavailable in this copy of Brim."
    }
}
