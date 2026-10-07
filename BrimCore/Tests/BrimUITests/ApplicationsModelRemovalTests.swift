import BrimCore
import BrimProtocol
@testable import BrimUI
import XCTest

/// Removing an application must take its row off screen at once. Waiting for
/// a full re-enumeration leaves a removed app visible for seconds after the
/// sheet says nothing remains.
@MainActor
final class ApplicationsModelRemovalTests: XCTestCase {
    private func app(at url: URL) -> InstalledApplication {
        InstalledApplication(
            identity: Identity(bundleID: "com.t.\(url.lastPathComponent)", name: url.lastPathComponent),
            url: url,
            bundleSizeBytes: 1,
            isSystemProtected: false
        )
    }

    func testARemovedApplicationLeavesTheListImmediately() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let goneURL = dir.appendingPathComponent("Gone.app")
        let stillURL = dir.appendingPathComponent("Still.app")
        try FileManager.default.createDirectory(at: goneURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stillURL, withIntermediateDirectories: true)

        let gone = app(at: goneURL)
        let still = app(at: stillURL)
        let model = ApplicationsModel()
        await model.load(service: StubInventoryService(applications: [gone, still]))
        model.select(gone)

        // Still on disk: nothing is dropped on the sheet's word alone.
        XCTAssertFalse(model.forgetIfRemoved(gone))
        XCTAssertEqual(model.applications.count, 2)

        try FileManager.default.removeItem(at: goneURL)
        XCTAssertTrue(model.forgetIfRemoved(gone))
        XCTAssertEqual(model.applications.map(\.id), [still.id])
        XCTAssertNil(model.selected, "A removed app must not stay selected")
        XCTAssertNil(model.footprint)
    }

    /// eqMac stayed in the inspector with its old footprint and a Remove
    /// button after it was removed, because the panel that removed it went
    /// away without reporting the finish. A fresh list settles it.
    func testAReloadWithoutTheSelectedAppClearsTheSelection() async {
        let gone = app(at: URL(fileURLWithPath: "/Applications/Gone.app"))
        let still = app(at: URL(fileURLWithPath: "/Applications/Still.app"))
        let model = ApplicationsModel()
        await model.load(service: StubInventoryService(applications: [gone, still]))
        model.select(gone)
        await model.load(service: StubInventoryService(applications: [still]))
        XCTAssertNil(model.selected)
        XCTAssertNil(model.footprint)
    }

    func testTheSharedTierIsLabelledSharedRatherThanGuaranteed() {
        // It read "Guaranteed", which is the opposite of what Tier S means
        // and would have read to a person as a reason to remove the item
        // with confidence. S says another application claims it.
        XCTAssertEqual(EvidenceTier.S.shortLabel, "Shared")
        XCTAssertEqual(EvidenceTier.A.shortLabel, "Direct")
    }
}

private actor StubInventoryService: BrimServiceProtocol {
    let applications: [InstalledApplication]
    init(applications: [InstalledApplication]) {
        self.applications = applications
    }

    func installedApplications() async throws -> [InstalledApplication] {
        applications
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw Nope.unavailable
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw Nope.unavailable
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw Nope.unavailable
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw Nope.unavailable
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw Nope.unavailable
    }

    func history() async throws -> [Plan] {
        []
    }

    func undo(planId _: UUID) async throws {
        throw Nope.unavailable
    }

    func leftovers() async throws -> [Leftover] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }
}

private enum Nope: Error { case unavailable }
