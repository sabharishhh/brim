import Foundation
import BrimProtocol
import BrimCore

public actor BrimXPCClient: BrimServiceProtocol {
    private let connection: NSXPCConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(connection: NSXPCConnection, requireCodeSigning: Bool = true) {
        if requireCodeSigning {
            MutualAuthentication.secure(connection)
        }
        self.connection = connection
    }

    private func withProxy<T: Sendable>(_ perform: @escaping @Sendable (BrimXPCProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            } as? BrimXPCProtocol
            
            guard let proxy = proxy else {
                continuation.resume(throwing: NSError(domain: "BrimXPC", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to get proxy"]))
                return
            }
            
            perform(proxy) { result in
                continuation.resume(with: result)
            }
        }
    }

    public func inspect(identity: Identity) async throws -> Footprint {
        let data = try encoder.encode(identity)
        let resultData: Data = try await withProxy { proxy, reply in
            proxy.inspect(identityData: data) { data, error in
                if let error = error { reply(.failure(error)) }
                else if let data = data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
        return try decoder.decode(Footprint.self, from: resultData)
    }

    public func plan(intent: PlanIntent) async throws -> Plan {
        let data = try encoder.encode(intent)
        let resultData: Data = try await withProxy { proxy, reply in
            proxy.plan(intentData: data) { data, error in
                if let error = error { reply(.failure(error)) }
                else if let data = data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
        return try decoder.decode(Plan.self, from: resultData)
    }

    public func explain(planId: UUID) async throws -> String {
        return try await withProxy { proxy, reply in
            proxy.explain(planIdString: planId.uuidString) { string, error in
                if let error = error { reply(.failure(error)) }
                else if let string = string { reply(.success(string)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
    }



    public func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalToken {
        let resultData: Data = try await withProxy { proxy, reply in
            proxy.requestApproval(planIdString: planId.uuidString, requesterIdentity: requesterIdentity) { data, error in
                if let error = error { reply(.failure(error)) }
                else if let data = data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
        return try decoder.decode(ApprovalToken.self, from: resultData)
    }

    public func apply(planId: UUID, token: ApprovalToken) async throws {
        let data = try encoder.encode(token)
        try await withProxy { (proxy: BrimXPCProtocol, reply: @escaping @Sendable (Result<Void, Error>) -> Void) in
            proxy.apply(planIdString: planId.uuidString, tokenData: data) { error in
                if let error = error { reply(.failure(error)) }
                else { reply(.success(())) }
            }
        }
    }

    public func verify(planId: UUID) async throws -> VerificationResult {
        let resultData: Data = try await withProxy { proxy, reply in
            proxy.verify(planIdString: planId.uuidString) { data, error in
                if let error = error { reply(.failure(error)) }
                else if let data = data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
        return try decoder.decode(VerificationResult.self, from: resultData)
    }

    public func history() async throws -> [Plan] {
        let resultData: Data = try await withProxy { proxy, reply in
            proxy.history { data, error in
                if let error = error { reply(.failure(error)) }
                else if let data = data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
        return try decoder.decode([Plan].self, from: resultData)
    }

    public func undo(planId: UUID) async throws {
        try await withProxy { (proxy: BrimXPCProtocol, reply: @escaping @Sendable (Result<Void, Error>) -> Void) in
            proxy.undo(planIdString: planId.uuidString) { error in
                if let error = error { reply(.failure(error)) }
                else { reply(.success(())) }
            }
        }
    }

    public func dumpBTM() async throws -> String {
        return try await withProxy { (proxy: BrimXPCProtocol, reply: @escaping @Sendable (Result<String, Error>) -> Void) in
            proxy.dumpBTM { result, error in
                if let error = error { reply(.failure(error)) }
                else if let result = result { reply(.success(result)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
    }

    public func leftovers() async throws -> [Leftover] {
        let resultData: Data = try await withProxy { proxy, reply in
            proxy.leftovers { data, error in
                if let error = error { reply(.failure(error)) }
                else if let data = data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
        return try decoder.decode([Leftover].self, from: resultData)
    }

    public func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] {
        let resultData: Data = try await withProxy { proxy, reply in
            proxy.scanDuplicates(directoryURLString: directory.path) { data, error in
                if let error = error { reply(.failure(error)) }
                else if let data = data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
        return try decoder.decode([DuplicateGroup].self, from: resultData)
    }
}
