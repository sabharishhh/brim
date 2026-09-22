import Foundation
import BrimProtocol
import BrimCore

public final class BrimXPCServer: NSObject, BrimXPCProtocol, @unchecked Sendable {
    private let service: BrimServiceProtocol

    public init(service: BrimServiceProtocol) {
        self.service = service
        super.init()
    }

    public func whatChanged(withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let history = await service.whatChanged()
                reply(try JSONEncoder().encode(history), nil)
            } catch {
                reply(nil, Self.wire(error))
            }
        }
    }

    public func updateReport(withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                reply(try JSONEncoder().encode(await service.updateReport()), nil)
            } catch {
                reply(nil, Self.wire(error))
            }
        }
    }

    /// Carries the sentence across the connection.
    ///
    /// A Swift error's `localizedDescription` is computed, not stored, so
    /// bridging one straight to `NSError` and sending it over XPC arrives
    /// as `Code=0 "(null)"`. A refusal that says nothing gets read as a
    /// bug and worked around, which is the opposite of what a refusal is
    /// for. This pins the sentence into the user info before it travels.
    static func wire(_ error: Error) -> NSError {
        let bridged = error as NSError
        if bridged.userInfo[NSLocalizedDescriptionKey] != nil { return bridged }
        return NSError(
            domain: bridged.domain, code: bridged.code,
            userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
        )
    }

    public func inspect(identityData: Data, withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let identity = try { () -> JSONDecoder in let d = JSONDecoder(); return d }().decode(Identity.self, from: identityData)
                let footprint = try await service.inspect(identity: identity)
                let data = try { () -> JSONEncoder in let e = JSONEncoder(); return e }().encode(footprint)
                reply(data, nil)
            } catch {
                reply(nil, Self.wire(error))
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
                reply(nil, Self.wire(error))
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
                reply(nil, Self.wire(error))
            }
        }
    }



    public func requestApproval(planIdString: String, requesterIdentity: String, withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        guard let planId = UUID(uuidString: planIdString) else {
            reply(nil, NSError(domain: "BrimXPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID string"]))
            return
        }
        Task {
            do {
                let receipt = try await service.requestApproval(planId: planId, requesterIdentity: requesterIdentity)
                let data = try JSONEncoder().encode(receipt)
                reply(data, nil)
            } catch {
                reply(nil, Self.wire(error))
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
                reply(Self.wire(error))
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
                reply(nil, Self.wire(error))
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
                reply(nil, Self.wire(error))
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
                reply(Self.wire(error))
            }
        }
    }

    public func leftovers(withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let leftovers = try await service.leftovers()
                let data = try JSONEncoder().encode(leftovers)
                reply(data, nil)
            } catch {
                reply(nil, Self.wire(error))
            }
        }
    }
    public func installedApplications(withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let apps = try await service.installedApplications()
                reply(try JSONEncoder().encode(apps), nil)
            } catch {
                reply(nil, Self.wire(error))
            }
        }
    }

    public func recoverableItems(withReply reply: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let items = try await service.recoverableItems()
                let data = try JSONEncoder().encode(items)
                reply(data, nil)
            } catch {
                reply(nil, Self.wire(error))
            }
        }
    }
}
