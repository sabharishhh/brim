import BrimCore
import BrimProtocol
@testable import BrimUI
import XCTest

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

    func installedApplications() async throws -> [InstalledApplication] {
        apps
    }

    func inspect(identity: Identity) async throws -> Footprint {
        inspectCalls.append(identity.name)
        if identity.name == "Unreadable" {
            throw URLError(.noPermissionsToReadFile)
        }
        if gated {
            await withCheckedContinuation { gate = $0 }
        }
        return footprints[identity.name] ?? Footprint(identity: identity, items: [])
    }

    func release() {
        gate?.resume(); gate = nil
    }

    func calls() -> [String] {
        inspectCalls
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw Stub.unavailable
    }

    func explain(planId _: UUID) async throws -> String {
        throw Stub.unavailable
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw Stub.unavailable
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw Stub.unavailable
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw Stub.unavailable
    }

    func history() async throws -> [Plan] {
        []
    }

    func undo(planId _: UUID) async throws {
        throw Stub.unavailable
    }

    func leftovers() async throws -> [Leftover] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }
}

private enum Stub: Error { case unavailable }

private func app(_ name: String, bundleID: String? = nil, protected: Bool = false) -> InstalledApplication {
    InstalledApplication(
        identity: Identity(bundleID: bundleID ?? "com.test.\(name.lowercased())", name: name),
        url: URL(fileURLWithPath: "/Applications/\(name).app"),
        bundleSizeBytes: 1024,
        isSystemProtected: protected
    )
}

private func item(
    _ path: String,
    mechanism: String,
    tier: EvidenceTier,
    bytes: Int64,
    sentence: String = "because"
) -> FootprintItem {
    FootprintItem(
        evidence: Evidence(url: URL(fileURLWithPath: path), tier: tier, mechanism: mechanism, humanSentence: sentence),
        sizeBytes: bytes,
        capability: .ok
    )
}

@MainActor
final class ApplicationsModelTests: XCTestCase {
    /// Command-click marks apps for one review, as in Finder: the app
    /// already selected is the first mark, one mark is just a selection, and
    /// an app that is part of macOS cannot be marked.
    func testMarkingSeveralAppsForOneReview() {
        let model = ApplicationsModel()
        let alpha = app("Alpha"), beta = app("Beta"), gamma = app("Gamma"), system = app("Safari", protected: true)
        model.select(alpha)
        model.toggleMark(beta)
        XCTAssertEqual(model.marked.map(\.name), ["Alpha", "Beta"])
        model.toggleMark(system)
        XCTAssertEqual(model.marked.count, 2, "part of macOS is not marked")
        model.toggleMark(gamma)
        XCTAssertEqual(model.marked.count, 3)
        model.toggleMark(beta)
        model.toggleMark(gamma)
        XCTAssertTrue(model.marked.isEmpty, "one mark is a selection")
        XCTAssertEqual(model.selected?.name, "Alpha")
        model.toggleMark(beta)
        model.select(gamma)
        XCTAssertTrue(model.marked.isEmpty, "a plain click ends marking")
    }

    /// The Select button: a click ticks rather than opens, one tick is
    /// allowed while choosing, the open app starts ticked, and Done or a
    /// plain selection ends it.
    func testChoosingTicksAppsOneClickAtATime() {
        let model = ApplicationsModel()
        let alpha = app("Alpha"), beta = app("Beta"), system = app("Safari", protected: true)
        model.select(alpha)
        model.startChoosing()
        XCTAssertEqual(model.marked.map(\.name), ["Alpha"])
        model.toggleChoice(alpha)
        XCTAssertTrue(model.marked.isEmpty)
        XCTAssertTrue(model.isChoosing, "no ticks is still choosing")
        model.toggleChoice(beta)
        model.toggleChoice(system)
        XCTAssertEqual(model.marked.map(\.name), ["Beta"])
        model.stopChoosing()
        XCTAssertFalse(model.isChoosing)
        XCTAssertTrue(model.marked.isEmpty)
        model.startChoosing()
        model.select(beta)
        XCTAssertFalse(model.isChoosing)
    }

    func testATableSelectionOfSeveralRowsMarksThem() {
        let model = ApplicationsModel()
        model.mark([app("Alpha"), app("Beta")])
        XCTAssertEqual(model.marked.count, 2)
        model.mark([app("Alpha"), app("Safari", protected: true)])
        XCTAssertTrue(model.marked.isEmpty)
        XCTAssertEqual(model.selected?.name, "Alpha")
    }

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

        XCTAssertEqual(
            model.uninstallBlockedReason,
            "macOS protects this application. It is part of the system and cannot be removed."
        )
    }

    func testAnOrdinaryApplicationCanBeUninstalled() async {
        let model = ApplicationsModel()
        await model.load(service: AppsStub(apps: [app("Figma")]))
        model.select(model.applications.first)

        XCTAssertNotNil(model.selected)
        XCTAssertNil(model.uninstallBlockedReason)
    }

    /// A footprint that could not be read was never shown: the failure
    /// went into the list's error, which the inspector does not read, and
    /// the pane showed the app with nothing under it.
    func testAFailedInspectionIsTheInspectorsToSay() async throws {
        let model = ApplicationsModel()
        await model.load(service: AppsStub(apps: [app("Unreadable"), app("Figma")]))
        model.select(model.applications.first { $0.name == "Unreadable" })
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(model.inspectionError)
        XCTAssertNil(model.footprint)
        XCTAssertNil(model.errorMessage, "The list itself was read")

        model.select(model.applications.first { $0.name == "Figma" })
        XCTAssertNil(model.inspectionError)
    }

    func testAFailedListingIsReported() async {
        let model = ApplicationsModel()
        await model.load(service: FailingAppsService())

        XCTAssertTrue(model.applications.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }
}
