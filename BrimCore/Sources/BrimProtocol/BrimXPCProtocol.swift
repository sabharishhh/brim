import Foundation
import BrimCore

@objc public protocol BrimXPCProtocol {
    func inspect(identityData: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func plan(intentData: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func explain(planIdString: String, withReply reply: @escaping @Sendable (String?, Error?) -> Void)
    func requestApproval(planIdString: String, requesterIdentity: String, withReply reply: @escaping @Sendable (Error?) -> Void)
    func apply(planIdString: String, tokenData: Data, withReply reply: @escaping @Sendable (Error?) -> Void)
    func verify(planIdString: String, withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func history(withReply reply: @escaping @Sendable (Data?, Error?) -> Void)
    func undo(planIdString: String, withReply reply: @escaping @Sendable (Error?) -> Void)
}
