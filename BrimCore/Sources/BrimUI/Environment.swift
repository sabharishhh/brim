import SwiftUI
import BrimProtocol
import BrimCore

public struct BrimServiceKey: EnvironmentKey {
    // The placeholder for previews. The app injects the real service at
    // launch.
    public static let defaultValue: any BrimServiceProtocol = DummyBrimService()
}

public extension EnvironmentValues {
    var brimService: any BrimServiceProtocol {
        get { self[BrimServiceKey.self] }
        set { self[BrimServiceKey.self] = newValue }
    }
}

/// Stands in for the service before the app injects the real one. Every
/// method throws the same refusal: crashing would take the app down, and an
/// empty answer would be a zero nobody measured.
public struct DummyBrimService: BrimServiceProtocol {
    public init() {}

    private var notConnected: Error {
        NSError(
            domain: "BrimService", code: 503,
            userInfo: [NSLocalizedDescriptionKey:
                "Brim is not connected to its service, so nothing has been read yet."]
        )
    }

    public func inspect(identity: Identity) async throws -> Footprint { throw notConnected }
    public func plan(intent: PlanIntent) async throws -> Plan { throw notConnected }
    public func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt { throw notConnected }
    public func apply(planId: UUID, token: ApprovalToken) async throws { throw notConnected }
    public func verify(planId: UUID) async throws -> VerificationResult { throw notConnected }
    public func history() async throws -> [Plan] { throw notConnected }
    public func undo(planId: UUID) async throws { throw notConnected }
    public func installedApplications() async throws -> [InstalledApplication] { throw notConnected }
    public func leftovers() async throws -> [Leftover] { throw notConnected }
    public func recoverableItems() async throws -> [RecoverableItem] { throw notConnected }
}
