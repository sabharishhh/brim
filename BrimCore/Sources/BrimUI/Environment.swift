import SwiftUI
import BrimProtocol
import BrimCore

public struct BrimServiceKey: EnvironmentKey {
    // The placeholder for previews. The app injects a real one at launch, and
    // anything reaching this one is a view that was rendered outside that
    // chain.
    public static let defaultValue: any BrimServiceProtocol = DummyBrimService()
}

public extension EnvironmentValues {
    var brimService: any BrimServiceProtocol {
        get { self[BrimServiceKey.self] }
        set { self[BrimServiceKey.self] = newValue }
    }
}

/// Stands in for the service before the app has injected the real one.
///
/// Two things were wrong with the previous version, and they pulled in
/// opposite directions. Half its methods called `fatalError()`, so a view
/// rendered outside the injection chain took the whole app down rather than
/// showing anything. The other half returned an empty array, which is worse
/// in a quieter way: a list that answers "no leftovers" without having looked
/// is the zero this product exists not to print.
///
/// Every method here throws the same refusal, so both cases come out as a
/// message somebody can read and report.
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
    public func explain(planId: UUID) async throws -> String { throw notConnected }
    public func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt { throw notConnected }
    public func apply(planId: UUID, token: ApprovalToken) async throws { throw notConnected }
    public func verify(planId: UUID) async throws -> VerificationResult { throw notConnected }
    public func history() async throws -> [Plan] { throw notConnected }
    public func undo(planId: UUID) async throws { throw notConnected }
    public func dumpBTM() async throws -> String { throw notConnected }
    public func installedApplications() async throws -> [InstalledApplication] { throw notConnected }
    public func leftovers() async throws -> [Leftover] { throw notConnected }
    public func recoverableItems() async throws -> [RecoverableItem] { throw notConnected }
    public func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] { throw notConnected }
}
