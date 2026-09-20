import Foundation
import BrimProtocol
import BrimCore

public final class BrimXPCServer: NSObject, BrimXPCProtocol, @unchecked Sendable {
    private let service: BrimServiceProtocol

    public init(service: BrimServiceProtocol) {
        self.service = service
        super.init()
    }

    public func inspect(identityData: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let identity = try { () -> JSONDecoder in let d = JSONDecoder(); return d }().decode(Identity.self, from: identityData)
                let footprint = try await service.inspect(identity: identity)
                let data = try { () -> JSONEncoder in let e = JSONEncoder(); return e }().encode(footprint)
                reply(data, nil)
            } catch {
                reply(nil, error as NSError)
            }
        }
    }

    public func plan(intentData: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let intent = try { () -> JSONDecoder in let d = JSONDecoder(); return d }().decode(PlanIntent.self, from: intentData)
                let plan = try await service.plan(intent: intent)
                let data = try { () -> JSONEncoder in let e = JSONEncoder(); return e }().encode(plan)
                reply(data, nil)
            } catch {
                reply(nil, error as NSError)
            }
        }
    }

    public func explain(planIdString: String, withReply reply: @escaping @Sendable (String?, Error?) -> Void) {
        guard let planId = UUID(uuidString: planIdString) else {
            reply(nil, NSError(domain: "BrimXPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID string"]))
            return
        }
        Task {
            do {
                let explanation = try await service.explain(planId: planId)
                reply(explanation, nil)
            } catch {
                reply(nil, error as NSError)
            }
        }
    }

    public func requestApproval(planIdString: String, requesterIdentity: String, withReply reply: @escaping @Sendable (Error?) -> Void) {
        guard let planId = UUID(uuidString: planIdString) else {
            reply(NSError(domain: "BrimXPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID string"]))
            return
        }
        Task {
            do {
                try await service.requestApproval(planId: planId, requesterIdentity: requesterIdentity)
                reply(nil)
            } catch {
                reply(error as NSError)
            }
        }
    }

    public func apply(planIdString: String, tokenData: Data, withReply reply: @escaping @Sendable (Error?) -> Void) {
        guard let planId = UUID(uuidString: planIdString) else {
            reply(NSError(domain: "BrimXPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID string"]))
            return
        }
        Task {
            do {
                let token = try { () -> JSONDecoder in let d = JSONDecoder(); return d }().decode(ApprovalToken.self, from: tokenData)
                try await service.apply(planId: planId, token: token)
                reply(nil)
            } catch {
                reply(error as NSError)
            }
        }
    }

    public func verify(planIdString: String, withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        guard let planId = UUID(uuidString: planIdString) else {
            reply(nil, NSError(domain: "BrimXPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID string"]))
            return
        }
        Task {
            do {
                let result = try await service.verify(planId: planId)
                let data = try { () -> JSONEncoder in let e = JSONEncoder(); return e }().encode(result)
                reply(data, nil)
            } catch {
                reply(nil, error as NSError)
            }
        }
    }

    public func history(withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let history = try await service.history()
                let data = try { () -> JSONEncoder in let e = JSONEncoder(); return e }().encode(history)
                reply(data, nil)
            } catch {
                reply(nil, error as NSError)
            }
        }
    }

    public func undo(planIdString: String, withReply reply: @escaping @Sendable (Error?) -> Void) {
        guard let planId = UUID(uuidString: planIdString) else {
            reply(NSError(domain: "BrimXPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID string"]))
            return
        }
        Task {
            do {
                try await service.undo(planId: planId)
                reply(nil)
            } catch {
                reply(error as NSError)
            }
        }
    }
}
