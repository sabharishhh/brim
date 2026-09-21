import Foundation

/// The whole of what the root daemon will do.
///
/// Two methods. There is no "delete this path", no "run this command", and
/// nothing that takes a URL, because an interface that cannot express a
/// dangerous request cannot be talked into one.
@objc public protocol BrimJobHelperProtocol {
    /// Sets aside one launchd job file that is no longer good for
    /// anything. The daemon builds the path from the domain and the name
    /// and applies its own rules; see `PrivilegedJobRemoval`.
    ///
    /// The reply carries nil when it worked, or a sentence saying why not.
    func removeDefunctJob(
        domain: String, name: String,
        withReply reply: @escaping (String?) -> Void
    )

    /// So the app can tell whether the installed daemon is the one that
    /// shipped with it, rather than an older copy left by a previous
    /// version.
    func version(withReply reply: @escaping (String) -> Void)
}

public enum BrimJobHelper {
    /// Must match the daemon's launchd plist and the bundle identifier
    /// prefix, or `SMAppService` refuses to register it.
    public static let machServiceName = "com.sabharishhh.brim.jobhelper"

    /// Bumped whenever the daemon's behaviour changes, so the app can
    /// replace a stale copy rather than talk to it.
    public static let version = "1"

    public static let teamID = "9LY29YLFG2"

    /// What the daemon demands of anything that connects to it: the
    /// application, and nothing else.
    ///
    /// Anchored to Apple, pinned to this application and this team. The
    /// previous attempt at this pinned `com.google.Brim` and team
    /// `EQHXZ8M8AV`, which is Google's, and then accepted every
    /// connection anyway because the result was never checked.
    public static func clientRequirement(
        bundleID: String = "com.sabharishhh.brim",
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

    private static func requirement(identifier: String, teamID: String) -> String {
        "anchor apple generic"
        + " and identifier \"\(identifier)\""
        + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Where a removed job file is kept, so this is undoable. Root owned,
    /// and on the same volume as both launchd directories, which is what
    /// lets the move be a rename rather than a copy and a delete.
    public static let quarantineDirectory = "/Library/Application Support/Brim/Set aside"
}
