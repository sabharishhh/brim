import Foundation
import Security

/// The whole of what the root daemon will do.
///
/// A few narrow methods. There is no "delete this path", no "run this
/// command", and nothing that takes a URL, because an interface that
/// cannot express a dangerous request cannot be talked into one.
@objc public protocol BrimJobHelperProtocol {
    /// Sets aside one launchd job file that is no longer good for
    /// anything. The daemon builds the path from the domain and the name
    /// and applies its own rules; see `PrivilegedJobRemoval`.
    ///
    /// The reply carries nil when it worked, or a sentence saying why not.
    func removeDefunctJob(
        domain: String, name: String,
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    /// Sets aside one command link that points at nothing. The daemon
    /// builds the path from the domain and the name and proves the link is
    /// dead itself; see `PrivilegedLinkRemoval`.
    ///
    /// The reply carries nil when it worked, or a sentence saying why not.
    func removeBrokenCommand(
        domain: String, name: String,
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    /// Forgets one installer receipt. Deletes no files: the record lives
    /// in a folder that belongs to root, which is the only reason this is
    /// here. The daemon applies its own rules; see
    /// `PrivilegedReceiptRemoval`.
    ///
    /// The reply carries nil when it worked, or a sentence saying why not.
    func forgetReceipt(packageID: String, withReply reply: @escaping @Sendable (String?) -> Void)

    /// Sets aside an application or plug-in an installer left owned by
    /// root. See `PrivilegedBundleRemoval` for what it will and will not
    /// take. Nil when it worked, otherwise why not.
    func removeInstalledBundle(
        domain: String, name: String,
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    /// Sets aside an application an installer put outside the
    /// Applications folders, found through the package's own receipt. See
    /// `PrivilegedPayloadRemoval`. Nil when it worked, otherwise why not.
    func removeInstalledPayload(
        packageID: String, name: String,
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    /// Sets aside one item in `/Library/Caches`. See
    /// `PrivilegedCacheRemoval`. Nil when it worked, otherwise why not.
    func removeSystemCache(name: String, withReply reply: @escaping @Sendable (String?) -> Void)

    /// Sets aside one preference file in `/Library/Preferences`. See
    /// `PrivilegedPreferenceRemoval`. Nil when it worked, otherwise why not.
    func removeSystemPreference(name: String, withReply reply: @escaping @Sendable (String?) -> Void)

    /// Lists only Brim's fixed recovery store. The payload is a JSON array.
    func recoveryItems(withReply reply: @escaping @Sendable (Data?, String?) -> Void)

    /// Permanently removes one selected recovery copy after checking its identity.
    func removeRecoveryItem(
        identifier: String, expectedDevice: Int32, expectedInode: UInt64,
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    /// So the app can tell whether the installed daemon is the one that
    /// shipped with it, rather than an older copy left by a previous
    /// version.
    func version(withReply reply: @escaping @Sendable (String) -> Void)

    /// Clears up what only root can, on the way out.
    ///
    /// `SMAppService.unregister` is the application's call and takes the
    /// daemon away, but it cannot touch the quarantine: that directory is
    /// root owned and holds the job files Brim set aside, so an uninstall
    /// without this leaves a root-owned folder behind. A product whose
    /// argument is that it removes every trace does not get to make an
    /// exception for its own.
    ///
    /// Destroys the set-aside files, so it is only ever called when
    /// somebody has asked for Brim itself to go.
    func uninstallSelf(withReply reply: @escaping @Sendable (String?) -> Void)
}

public enum BrimJobHelper {
    /// Must match the daemon's launchd plist and the bundle identifier
    /// prefix, or `SMAppService` refuses to register it.
    public static let machServiceName = "com.sabharishhh.brim.jobhelper"

    /// Bumped whenever the daemon's behaviour changes, so the app can
    /// replace a stale copy rather than talk to it.
    public static let version = "12"

    public static let teamID = "9LY29YLFG2"

    /// What the daemon demands of anything that connects to it: the
    /// application, and nothing else.
    ///
    /// Anchored to Apple, pinned to this application and this team. The
    /// previous attempt at this pinned `com.google.Brim` and team
    /// `EQHXZ8M8AV`, which is Google's, and then accepted every
    /// connection anyway because the result was never checked.
    public static func clientRequirement(
        bundleID: String = applicationIdentifier,
        teamID: String = BrimJobHelper.teamID
    ) -> String {
        requirement(identifier: bundleID, teamID: teamID)
    }

    /// What the application demands of the daemon it is talking to.
    ///
    /// A separate requirement, because the two are separate identities
    /// and pinning the wrong one is easy: the first version had the app
    /// checking the daemon against the *app's* identifier, which nothing
    /// could ever satisfy. Both directions are checked, because a root
    /// service accepting whatever answers is how one gets replaced.
    public static func daemonRequirement(
        identifier: String = "com.sabharishhh.brim.jobhelper",
        teamID: String = BrimJobHelper.teamID
    ) -> String {
        requirement(identifier: identifier, teamID: teamID)
    }

    /// Whether a requirement string is one the system can evaluate.
    /// `setCodeSigningRequirement` raises on one it cannot parse, and the
    /// daemon refuses rather than crashes.
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

    /// Where a removed job file is kept, so this is undoable. Root owned,
    /// and on the same volume as both launchd directories, which is what
    /// lets the move be a rename rather than a copy and a delete.
    public static let quarantineDirectory = "/Library/Application Support/Brim/Set aside"
}
