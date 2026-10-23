import Foundation
import Security

/// Everything the administrator process will do: a few narrow methods. No
/// "delete this path", no "run this command", nothing that takes a URL,
/// because an interface that cannot express a dangerous request cannot be
/// talked into one.
@objc public protocol BrimJobHelperProtocol {
    /// Sets aside one launchd job file that is no longer good for anything. The
    /// path is built here from the domain and name, under its own rules
    /// (`PrivilegedJobRemoval`). Replies nil on success, or why not.
    func removeDefunctJob(
        domain: String, name: String,
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    /// Sets aside one command link that points at nothing, proving it dead here
    /// (`PrivilegedLinkRemoval`). Replies nil on success, or why not.
    func removeBrokenCommand(
        domain: String, name: String,
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    /// Forgets one installer receipt. Deletes no files; it is here only because
    /// the record lives in a root-owned folder (`PrivilegedReceiptRemoval`).
    /// Replies nil on success, or why not.
    func forgetReceipt(packageID: String, withReply reply: @escaping @Sendable (String?) -> Void)

    /// Sets aside an app or plug-in an installer left owned by root
    /// (`PrivilegedBundleRemoval`). Nil on success, otherwise why not.
    func removeInstalledBundle(
        domain: String, name: String,
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    /// Sets aside an app an installer put outside the Applications folders,
    /// found through the package's own receipt (`PrivilegedPayloadRemoval`).
    /// Nil on success, otherwise why not.
    func removeInstalledPayload(
        packageID: String, name: String,
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    /// Sets aside one item in `/Library/Caches` (`PrivilegedCacheRemoval`). Nil
    /// on success, otherwise why not.
    func removeSystemCache(name: String, withReply reply: @escaping @Sendable (String?) -> Void)

    /// Sets aside one preference file in `/Library/Preferences`
    /// (`PrivilegedPreferenceRemoval`). Nil on success, otherwise why not.
    func removeSystemPreference(name: String, withReply reply: @escaping @Sendable (String?) -> Void)

    /// Lists only Brim's fixed recovery store. The payload is a JSON array.
    func recoveryItems(withReply reply: @escaping @Sendable (Data?, String?) -> Void)

    /// Permanently removes one selected recovery copy after checking its identity.
    func removeRecoveryItem(
        identifier: String, expectedDevice: Int32, expectedInode: UInt64,
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    /// Lets the app check this helper is the one that shipped with it.
    func version(withReply reply: @escaping @Sendable (String) -> Void)

    /// Clears what only root can, when Brim itself is being removed: the
    /// root-owned folder of set-aside files. Destroys those files, so it is only
    /// called when the person has asked for Brim to go.
    func uninstallSelf(withReply reply: @escaping @Sendable (String?) -> Void)
}

public enum BrimJobHelper {
    /// The temporary administrator process's identifier. Brim registers
    /// nothing with launchd or Background Task Management under it.
    public static let machServiceName = "com.sabharishhh.brim.jobhelper"

    /// Bumped whenever the helper's behaviour changes, so the app never talks
    /// to a stale copy.
    public static let version = "12"

    public static let teamID = "9LY29YLFG2"

    /// What the administrator process demands of anything connecting to it:
    /// Brim's application and nothing else. Anchored to Apple and pinned to this
    /// identifier and team.
    public static func clientRequirement(
        bundleID: String = applicationIdentifier,
        teamID: String = BrimJobHelper.teamID
    ) -> String {
        requirement(identifier: bundleID, teamID: teamID)
    }

    /// What the application demands of the administrator process: a separate
    /// identity from the app's, and both directions are checked. With
    /// `codeHash`, only that one build of the helper; the team alone would let
    /// any older helper the team signed run as root.
    public static func daemonRequirement(
        identifier: String = machServiceName,
        teamID: String = BrimJobHelper.teamID,
        codeHash: String? = nil
    ) -> String {
        let base = requirement(identifier: identifier, teamID: teamID)
        guard let codeHash, codeHash.count == 40 || codeHash.count == 64,
              codeHash.allSatisfy(\.isHexDigit) else { return base }
        return base + " and cdhash H\"\(codeHash.lowercased())\""
    }

    /// The helper's code hash, read only after the application around it passes
    /// its own signature check, nested code included, so what is pinned is the
    /// helper this copy of Brim was signed with.
    public static func sealedHelperHash(_ executable: URL) throws -> String {
        let application = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var applicationCode: SecStaticCode?
        var compiled: SecRequirement?
        guard SecStaticCodeCreateWithPath(application as CFURL, [], &applicationCode) == errSecSuccess,
              let applicationCode,
              SecRequirementCreateWithString(clientRequirement() as CFString, [], &compiled) == errSecSuccess,
              let compiled,
              SecStaticCodeCheckValidity(
                  applicationCode,
                  SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                  compiled
              ) == errSecSuccess
        else { throw SealFailure.applicationNotSealed }
        var helperCode: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &helperCode) == errSecSuccess, let helperCode,
              SecCodeCopySigningInformation(helperCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
              == errSecSuccess,
              let unique = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              !unique.isEmpty
        else { throw SealFailure.helperUnreadable }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    public enum SealFailure: Error, LocalizedError {
        case applicationNotSealed
        case helperUnreadable

        public var errorDescription: String? {
            switch self {
            case .applicationNotSealed: "Brim's own signature does not check out, so it will not ask for root."
            case .helperUnreadable: "Brim could not read its administrator helper's signature."
            }
        }
    }

    /// Whether a requirement string is one the system can evaluate.
    /// `setCodeSigningRequirement` raises on one it cannot parse, so it is
    /// checked first and refused rather than crashing.
    public static func isWellFormed(_ requirement: String) -> Bool {
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        return status == errSecSuccess && compiled != nil
    }

    private static func requirement(identifier: String, teamID: String) -> String {
        "anchor apple generic"
            + " and identifier \"\(identifier)\""
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// The application this helper serves, the one identity it accepts.
    public static let applicationIdentifier = "com.sabharishhh.brim"

    /// Where set-aside items are kept, so a removal can be undone. Root owned,
    /// and on the same volume as the launchd folders, so a move is a rename.
    public static let quarantineDirectory = "/Library/Application Support/Brim/Set aside"
}
