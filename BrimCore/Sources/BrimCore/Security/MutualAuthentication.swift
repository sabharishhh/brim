import Foundation
import Security

/// Which of Brim's signed components is expected at the other end.
public enum BrimPeer: String, Sendable, CaseIterable {
    /// Brim's application.
    case application
    /// Brim's privileged daemon.
    case daemon

    /// The code-signing identifier, which is not the Mach service name and
    /// is not the display name. Pinning the wrong one of the three is the
    /// mistake this enum exists to stop being possible.
    public var signingIdentifier: String {
        switch self {
        case .application: return "com.sabharishhh.brim"
        case .daemon: return "com.sabharishhh.brim.daemon"
        }
    }
}

/// What a connection is allowed to be talking to.
public enum XPCPeerExpectation: Sendable {
    /// Pin the far end to one of Brim's signed components.
    case brim(BrimPeer)

    /// An anonymous endpoint inside this process.
    ///
    /// Not a trust boundary and not an exemption from one. An anonymous
    /// listener's endpoint cannot be guessed or looked up; it only reaches
    /// anyone who was handed the endpoint object, which here never leaves
    /// the process that made it. There is nothing on the other side to
    /// authenticate, and pinning would only ever reject the caller itself,
    /// because a binary from `swift build` carries no team.
    case sameProcessAnonymous
}

/// Who is allowed to talk to whom.
///
/// Three things were wrong here, and each of them on its own was enough to
/// make the check worthless.
///
/// The requirement named `com.google.Brim` and team `EQHXZ8M8AV`, which is
/// Google's, so nothing Brim signs could ever have satisfied it. The debug
/// branch dropped the anchor and the team entirely, leaving a bare
/// identifier that any process can claim by naming itself. And none of it
/// ran: every call site but one passed `requireCodeSigning: false`, so no
/// requirement was installed on any connection the product actually makes.
///
/// `setCodeSigningRequirement` returns nothing and raises an Objective-C
/// exception on a string it cannot parse, which in Swift is a crash rather
/// than a refusal. So the string is compiled with
/// `SecRequirementCreateWithString` first: a bad requirement becomes a
/// connection Brim declines to make, which is the direction a security
/// check should fail in.
///
/// There is no separate development path, on purpose. `anchor apple
/// generic` with the team in the leaf is satisfied by an Apple Development
/// certificate and by Developer ID alike, so one string covers both and
/// there is no looser variant that could be left switched on in a shipped
/// build.
public enum MutualAuthentication {

    /// The Apple Developer team this application is signed by. Everything
    /// Brim ships carries it, and nothing else does.
    public static let teamID = "9LY29YLFG2"

    /// Anchored to Apple, pinned to one identifier and one team.
    public static func requirement(
        for peer: BrimPeer, teamID: String = MutualAuthentication.teamID
    ) -> String {
        "anchor apple generic"
        + " and identifier \"\(peer.signingIdentifier)\""
        + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Whether a requirement string is one the system can actually
    /// evaluate. Compiling it here is what lets `pin` refuse instead of
    /// raising an exception out of `setCodeSigningRequirement`.
    public static func isWellFormed(_ requirement: String) -> Bool {
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(
            requirement as CFString, [], &compiled
        )
        return status == errSecSuccess && compiled != nil
    }

    /// Applies the requirement, and says whether it took.
    ///
    /// Every caller has to treat false as a refusal. A connection that was
    /// meant to be pinned and is not is worse than one that was never
    /// pinned, because the rest of the code believes it was.
    ///
    /// Must be called before the interface is exported, never after.
    @discardableResult
    public static func pin(
        _ connection: NSXPCConnection, to expectation: XPCPeerExpectation
    ) -> Bool {
        switch expectation {
        case .sameProcessAnonymous:
            return true
        case .brim(let peer):
            let requirement = requirement(for: peer)
            guard isWellFormed(requirement) else { return false }
            connection.setCodeSigningRequirement(requirement)
            return true
        }
    }
}
