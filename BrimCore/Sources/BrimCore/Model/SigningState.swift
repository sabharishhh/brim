import Foundation

/// What the code behind a registration is signed with, and whether that
/// still matches what macOS recorded when it accepted the item.
///
/// T-3.8 asks for signing state on every background item, and the reason is
/// not tidiness. Background Task Management stores the team identifier and
/// a signing requirement alongside each record. If the code at that path is
/// now signed by somebody else, macOS's list and the disk disagree about
/// who is being allowed to run at login, which is worth saying out loud and
/// is not visible anywhere in System Settings.
public enum SigningState: Equatable, Sendable, Codable {
    /// Signed, and the signature holds up.
    case valid(team: String?)
    /// Signed by a different team than the one macOS recorded for it.
    case teamChanged(recorded: String, found: String?)
    /// A signature that does not check out.
    case invalid(String)
    case unsigned
    /// Not examined, and why. A path Brim cannot reach is not a verdict.
    case notChecked(String)

    /// One line for a person, saying the consequence rather than the
    /// category.
    public var sentence: String {
        switch self {
        case .valid(let team):
            guard let team else { return "Signed, and the signature checks out." }
            return "Signed by \(team), and the signature checks out."
        case .teamChanged(let recorded, let found):
            let now = found.map { "by \($0)" } ?? "without a team identifier"
            return "macOS recorded this as \(recorded) and the code here is signed \(now). "
                 + "Something replaced it after macOS agreed to run it."
        case .invalid(let reason):
            return "The signature does not check out. \(reason)"
        case .unsigned:
            return "Nothing signs this, so macOS cannot tell who wrote it."
        case .notChecked(let why):
            return why
        }
    }

    /// Two or three words for a table cell, where the sentence will not fit.
    ///
    /// A column that falls back to a dash when there is no team name says
    /// the same nothing for code that is unsigned, code whose signature is
    /// broken, and code Brim was not able to examine. Those are three
    /// different answers and the column has room to tell them apart.
    public var shortDescription: String {
        switch self {
        case .valid(let team): return team ?? "Signed"
        case .teamChanged(_, let found): return found.map { "Now \($0)" } ?? "Replaced"
        case .invalid: return "Signature broken"
        case .unsigned: return "Unsigned"
        case .notChecked: return "No code to read"
        }
    }

    /// Whether this is worth drawing attention to.
    public var isTrouble: Bool {
        switch self {
        case .valid, .notChecked: return false
        case .teamChanged, .invalid, .unsigned: return true
        }
    }
}
