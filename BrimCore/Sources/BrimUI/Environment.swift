import SwiftUI
import BrimProtocol
import BrimCore

public struct BrimServiceKey: EnvironmentKey {
    // We use a dummy for previews. The app must inject a real one.
    public static let defaultValue: any BrimServiceProtocol = DummyBrimService()
}

public extension EnvironmentValues {
    var brimService: any BrimServiceProtocol {
        get { self[BrimServiceKey.self] }
        set { self[BrimServiceKey.self] = newValue }
    }
}

public struct DummyBrimService: BrimServiceProtocol {
    public init() {}
    public func inspect(identity: Identity) async throws -> Footprint { fatalError() }
    public func plan(intent: PlanIntent) async throws -> Plan { fatalError() }
    public func explain(planId: UUID) async throws -> String { fatalError() }
    public func requestApproval(planId: UUID, requesterIdentity: String) async throws { fatalError() }
    public func apply(planId: UUID, token: ApprovalToken) async throws { fatalError() }
    public func verify(planId: UUID) async throws -> VerificationResult { fatalError() }
    public func history() async throws -> [Plan] { return [] }
    public func undo(planId: UUID) async throws { fatalError() }
}
