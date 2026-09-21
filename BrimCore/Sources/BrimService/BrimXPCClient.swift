import Foundation
import BrimProtocol
import BrimCore

public enum XPCAuthenticationError: LocalizedError {
    case couldNotPinPeer

    public var errorDescription: String? {
        "Brim could not require that the other end of this connection is Brim. "
        + "Rather than talk to whatever answers, it is not connecting at all."
    }
}

public actor BrimXPCClient: BrimServiceProtocol {
    private let connection: NSXPCConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Pins the far end, then starts the connection. Fails if it cannot.
    ///
    /// Throwing rather than returning a client that quietly talks to
    /// anything. Both directions are checked: the listener pins the app,
    /// and this pins the service, because a boundary guarded from one side
    /// is a boundary an impostor walks through from the other.
    ///
    /// Resuming is done here rather than by the caller so that the order
    /// cannot be got wrong. A requirement applied after the connection is
    /// live is a requirement that missed whatever was already in flight.
    public init(connection: NSXPCConnection, expecting: XPCPeerExpectation) throws {
        guard MutualAuthentication.pin(connection, to: expecting) else {
            connection.invalidate()
            throw XPCAuthenticationError.couldNotPinPeer
        }
        connection.resume()
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



    /// Note what is missing here: `BrimXPCClient` does not conform to
    /// `ApprovalGranting`. Whoever holds one of these can ask for approval
    /// and can apply a token they were given, and has no way at all to turn
    /// the first into the second.
    public func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt {
        let resultData: Data = try await withProxy { proxy, reply in
            proxy.requestApproval(planIdString: planId.uuidString, requesterIdentity: requesterIdentity) { data, error in
                if let error = error { reply(.failure(error)) }
                else if let data = data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
        return try decoder.decode(ApprovalRequestReceipt.self, from: resultData)
    }

    public func whatChanged() async -> InstallHistory {
        let empty = InstallHistory(changes: [], snapshots: 0)
        guard let data: Data = try? await withProxy({ proxy, reply in
            proxy.whatChanged { data, error in
                if let error { reply(.failure(error)) }
                else if let data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }) else { return empty }
        return (try? decoder.decode(InstallHistory.self, from: data)) ?? empty
    }

    public func updateReport() async -> UpdateReport {
        let empty = UpdateReport(coverage: [], agents: [], homebrewPresent: false)
        guard let data: Data = try? await withProxy({ proxy, reply in
            proxy.updateReport { data, error in
                if let error { reply(.failure(error)) }
                else if let data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }) else { return empty }
        return (try? decoder.decode(UpdateReport.self, from: data)) ?? empty
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

    public func installedApplications() async throws -> [InstalledApplication] {
        let resultData: Data = try await withProxy { proxy, reply in
            proxy.installedApplications { data, error in
                if let error = error { reply(.failure(error)) }
                else if let data = data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
        return try decoder.decode([InstalledApplication].self, from: resultData)
    }

    public func recoverableItems() async throws -> [RecoverableItem] {
        let resultData: Data = try await withProxy { proxy, reply in
            proxy.recoverableItems { data, error in
                if let error = error { reply(.failure(error)) }
                else if let data = data { reply(.success(data)) }
                else { reply(.failure(NSError(domain: "BrimXPC", code: 3, userInfo: nil))) }
            }
        }
        return try decoder.decode([RecoverableItem].self, from: resultData)
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
