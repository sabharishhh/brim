import Foundation
import BrimProtocol
import BrimCore

public actor BrimXPCClient: BrimServiceProtocol {
    private let connection: NSXPCConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(connection: NSXPCConnection) {
        self.connection = connection
    }

    private func getProxy() throws -> BrimXPCProtocol {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            print("XPC Connection Error: \(error)")
        }) as? BrimXPCProtocol else {
            throw NSError(domain: "BrimXPC", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to get remote object proxy"])
        }
        return proxy
    }

    public func inspect(identity: Identity) async throws -> Footprint {
        let data = try encoder.encode(identity)
        let proxy = try getProxy()
        let resultData: Data = try await withCheckedThrowingContinuation { continuation in
            proxy.inspect(identityData: data) { data, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NSError(domain: "BrimXPC", code: 3, userInfo: [NSLocalizedDescriptionKey: "No data and no error returned"]))
                }
            }
        }
        return try decoder.decode(Footprint.self, from: resultData)
    }

    public func plan(intent: PlanIntent) async throws -> Plan {
        let data = try encoder.encode(intent)
        let proxy = try getProxy()
        let resultData: Data = try await withCheckedThrowingContinuation { continuation in
            proxy.plan(intentData: data) { data, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NSError(domain: "BrimXPC", code: 3, userInfo: [NSLocalizedDescriptionKey: "No data and no error returned"]))
                }
            }
        }
        return try decoder.decode(Plan.self, from: resultData)
    }

    public func explain(planId: UUID) async throws -> String {
        let proxy = try getProxy()
        return try await withCheckedThrowingContinuation { continuation in
            proxy.explain(planIdString: planId.uuidString) { string, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let string = string {
                    continuation.resume(returning: string)
                } else {
                    continuation.resume(throwing: NSError(domain: "BrimXPC", code: 3, userInfo: [NSLocalizedDescriptionKey: "No string and no error returned"]))
                }
            }
        }
    }

    public func requestApproval(planId: UUID, requesterIdentity: String) async throws {
        let proxy = try getProxy()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.requestApproval(planIdString: planId.uuidString, requesterIdentity: requesterIdentity) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    public func apply(planId: UUID, token: ApprovalToken) async throws {
        let data = try encoder.encode(token)
        let proxy = try getProxy()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.apply(planIdString: planId.uuidString, tokenData: data) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    public func verify(planId: UUID) async throws -> VerificationResult {
        let proxy = try getProxy()
        let resultData: Data = try await withCheckedThrowingContinuation { continuation in
            proxy.verify(planIdString: planId.uuidString) { data, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NSError(domain: "BrimXPC", code: 3, userInfo: [NSLocalizedDescriptionKey: "No data and no error returned"]))
                }
            }
        }
        return try decoder.decode(VerificationResult.self, from: resultData)
    }

    public func history() async throws -> [Plan] {
        let proxy = try getProxy()
        let resultData: Data = try await withCheckedThrowingContinuation { continuation in
            proxy.history { data, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NSError(domain: "BrimXPC", code: 3, userInfo: [NSLocalizedDescriptionKey: "No data and no error returned"]))
                }
            }
        }
        return try decoder.decode([Plan].self, from: resultData)
    }

    public func undo(planId: UUID) async throws {
        let proxy = try getProxy()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.undo(planIdString: planId.uuidString) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
