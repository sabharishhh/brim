import XCTest
import BrimCore
import BrimProtocol
@testable import BrimUI

private actor AppsStub: BrimServiceProtocol {
    var apps: [InstalledApplication]
    var footprints: [String: Footprint]
    private(set) var inspectCalls: [String] = []
    /// Blocks `inspect` until released, so cancellation can be exercised.
    private var gate: CheckedContinuation<Void, Never>?
    private var gated = false

    init(apps: [InstalledApplication], footprints: [String: Footprint] = [:], gated: Bool = false) {
        self.apps = apps
        self.footprints = footprints
        self.gated = gated
    }

    func installedApplications() async throws -> [InstalledApplication] { apps }

    func inspect(identity: Identity) async throws -> Footprint {
        inspectCalls.append(identity.name)
        if gated {
            await withCheckedContinuation { gate = $0 }
        }
        return footprints[identity.name] ?? Footprint(identity: identity, items: [])
    }

    func release() { gate?.resume(); gate = nil }
    func calls() -> [String] { inspectCalls }

    func plan(intent: PlanIntent) async throws -> Plan { throw Stub.no }
    func explain(planId: UUID) async throws -> String { throw Stub.no }
    func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt { throw Stub.no }
    func apply(planId: UUID, token: ApprovalToken) async throws { throw Stub.no }
    func verify(planId: UUID) async throws -> VerificationResult { throw Stub.no }
    func history() async throws -> [Plan] { [] }
    func undo(planId: UUID) async throws { throw Stub.no }
    func dumpBTM() async throws -> String { "" }
    func leftovers() async throws -> [Leftover] { [] }
    func recoverableItems() async throws -> [RecoverableItem] { [] }
    func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] { [] }
}

private enum Stub: Error { case no }

private func app(_ name: String, bundleID: String? = nil, protected: Bool = false) -> InstalledApplication {
    InstalledApplication(
        identity: Identity(bundleID: bundleID ?? "com.test.\(name.lowercased())", name: name),
        url: URL(fileURLWithPath: "/Applications/\(name).app"),
        bundleSizeBytes: 1024,
        isSystemProtected: protected
    )
}

private func item(_ path: String, mechanism: String, tier: EvidenceTier, bytes: Int64, sentence: String = "because") -> FootprintItem {
    FootprintItem(
        evidence: Evidence(url: URL(fileURLWithPath: path), tier: tier, mechanism: mechanism, humanSentence: sentence),
        sizeBytes: bytes,
        capability: .ok
    )
}

@MainActor
final class ApplicationsModelTests: XCTestCase {

    func testSearchMatchesNameOrBundleIdentifier() async {
        let model = ApplicationsModel()
        await model.load(service: AppsStub(apps: [
            app("Figma", bundleID: "com.figma.Desktop"),
            app("Xcode", bundleID: "com.apple.dt.Xcode")
        ]))

        model.searchText = "figma"
        XCTAssertEqual(model.visibleApplications.map(\.name), ["Figma"])

        model.searchText = "apple.dt"
        XCTAssertEqual(model.visibleApplications.map(\.name), ["Xcode"], "Searching by bundle id should work")

        model.searchText = "   "
        XCTAssertEqual(model.visibleApplications.count, 2, "Whitespace is not a query")
    }

    func testFootprintIsGroupedByMechanismStrongestEvidenceFirst() async {
        let identity = Identity(bundleID: "com.test.app", name: "App")
        let footprint = Footprint(identity: identity, items: [
            item("/a", mechanism: "HeuristicSource", tier: .C, bytes: 900),
            item("/b", mechanism: "AppBundleSource", tier: .A, bytes: 100),
            item("/c", mechanism: "SandboxContainerSource", tier: .S, bytes: 50),
            item("/d", mechanism: "AppBundleSource", tier: .A, bytes: 10)
        ])

        let model = ApplicationsModel()
        let stub = AppsStub(apps: [app("App")], footprints: ["App": footprint])
        await model.load(service: stub)
        model.select(model.applications.first)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        let groups = model.footprintGroups
        XCTAssertEqual(groups.map(\.mechanism),
                       ["SandboxContainerSource", "AppBundleSource", "HeuristicSource"],
                       "Strongest evidence first, not largest first")
        XCTAssertEqual(groups.first { $0.mechanism == "AppBundleSource" }?.totalBytes, 110,
                       "Items sharing a mechanism are summed")
    }

    func testSelectingAnotherApplicationDiscardsTheFirstResult() async {
        // Clicking down a list must not leave a slow scan to overwrite the
        // footprint of whatever the user landed on.
        let stub = AppsStub(
            apps: [app("Slow"), app("Fast")],
            footprints: [
                "Slow": Footprint(identity: Identity(bundleID: "s", name: "Slow"),
                                  items: [item("/slow", mechanism: "M", tier: .A, bytes: 1)]),
                "Fast": Footprint(identity: Identity(bundleID: "f", name: "Fast"),
                                  items: [item("/fast", mechanism: "M", tier: .A, bytes: 2)])
            ]
        )

        let model = ApplicationsModel()
        await model.load(service: stub)

        model.select(model.applications.first { $0.name == "Slow" })
        model.select(model.applications.first { $0.name == "Fast" })
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(model.selected?.name, "Fast")
        XCTAssertEqual(model.footprint?.items.first?.evidence.url.path, "/fast",
                       "The abandoned scan must not land on the new selection")
    }

    func testDeselectingClearsTheFootprint() async {
        let model = ApplicationsModel()
        await model.load(service: AppsStub(apps: [app("App")]))
        model.select(model.applications.first)
        try? await Task.sleep(for: .milliseconds(50))

        model.select(nil)
        XCTAssertNil(model.selected)
        XCTAssertNil(model.footprint)
        XCTAssertFalse(model.isInspecting)
    }

    func testASystemApplicationCannotBeUninstalledAndSaysWhy() async {
        let model = ApplicationsModel()
        await model.load(service: AppsStub(apps: [app("Safari", bundleID: "com.apple.Safari", protected: true)]))
        model.select(model.applications.first)

        XCTAssertFalse(model.canUninstallSelection)
        XCTAssertEqual(
            model.uninstallBlockedReason,
            "macOS protects this application. It is part of the system and cannot be removed."
        )
    }

    func testAnOrdinaryApplicationCanBeUninstalled() async {
        let model = ApplicationsModel()
        await model.load(service: AppsStub(apps: [app("Figma")]))
        model.select(model.applications.first)

        XCTAssertTrue(model.canUninstallSelection)
        XCTAssertNil(model.uninstallBlockedReason)
    }

    func testAFailedListingIsReported() async {
        struct Failing: BrimServiceProtocol {
            func installedApplications() async throws -> [InstalledApplication] { throw Stub.no }
            func inspect(identity: Identity) async throws -> Footprint { throw Stub.no }
            func plan(intent: PlanIntent) async throws -> Plan { throw Stub.no }
            func explain(planId: UUID) async throws -> String { throw Stub.no }
            func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt { throw Stub.no }
            func apply(planId: UUID, token: ApprovalToken) async throws { throw Stub.no }
            func verify(planId: UUID) async throws -> VerificationResult { throw Stub.no }
            func history() async throws -> [Plan] { [] }
            func undo(planId: UUID) async throws { throw Stub.no }
            func dumpBTM() async throws -> String { "" }
            func leftovers() async throws -> [Leftover] { [] }
            func recoverableItems() async throws -> [RecoverableItem] { [] }
            func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] { [] }
        }

        let model = ApplicationsModel()
        await model.load(service: Failing())

        XCTAssertTrue(model.applications.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }
}

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
    init(applications: [InstalledApplication]) { self.applications = applications }

    func installedApplications() async throws -> [InstalledApplication] { applications }

    func plan(intent: PlanIntent) async throws -> Plan { throw Nope.no }
    func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt { throw Nope.no }
    func apply(planId: UUID, token: ApprovalToken) async throws { throw Nope.no }
    func verify(planId: UUID) async throws -> VerificationResult { throw Nope.no }
    func inspect(identity: Identity) async throws -> Footprint { throw Nope.no }
    func explain(planId: UUID) async throws -> String { throw Nope.no }
    func history() async throws -> [Plan] { [] }
    func undo(planId: UUID) async throws { throw Nope.no }
    func dumpBTM() async throws -> String { "" }
    func leftovers() async throws -> [Leftover] { [] }
    func recoverableItems() async throws -> [RecoverableItem] { [] }
    func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] { [] }
}

private enum Nope: Error { case no }
