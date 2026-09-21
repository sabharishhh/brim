import Foundation
import BrimCore

@objc public protocol BrimXPCProtocol {
    func inspect(identityData: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func plan(intentData: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func explain(planIdString: String, withReply reply: @escaping @Sendable (String?, Error?) -> Void)
    /// Returns an `ApprovalRequestReceipt`, never a token. There is no
    /// message on this interface that produces one, which is the point:
    /// a caller on the far side of the connection has nothing to call.
    func requestApproval(planIdString: String, requesterIdentity: String, withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func apply(planIdString: String, tokenData: Data, withReply reply: @escaping @Sendable (Error?) -> Void)
    func verify(planIdString: String, withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func history(withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func undo(planIdString: String, withReply reply: @escaping @Sendable (Error?) -> Void)
    func dumpBTM(withReply reply: @escaping @Sendable (String?, Error?) -> Void)
    func installedApplications(withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func leftovers(withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func recoverableItems(withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func scanDuplicates(directoryURLString: String, withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func whatChanged(withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func updateReport(withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
}
