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
    func leftovers() async throws -> [Leftover] { [] }
    func recoverableItems() async throws -> [RecoverableItem] { [] }
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

    func testFootprintIsGroupedStrongestEvidenceFirst() async {
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

    // MARK: - A header is a claim about every row under it

    private func groups(for items: [FootprintItem]) async -> [FootprintGroup] {
        let identity = Identity(bundleID: "com.test.app", name: "App")
        let model = ApplicationsModel()
        let stub = AppsStub(
            apps: [app("App")],
            footprints: ["App": Footprint(identity: identity, items: items)]
        )
        await model.load(service: stub)
        model.select(model.applications.first)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        return model.footprintGroups
    }

    /// **Seen in the running app, not in a test.** Visual Studio Code's
    /// footprint showed "The list macOS keeps of documents this application
    /// opened" above a group of caches, HTTP storage and per-machine
    /// preferences. Groups were keyed on the source that found each row and
    /// the header took the first row's sentence, and one source,
    /// `LocationInventorySource`, gives a different sentence for every place
    /// it looks. The recent-documents record sorted first, so its sentence
    /// described five rows that were nothing of the kind.
    func testAGroupsSentenceIsTrueOfEveryRowInIt() async {
        let found = await groups(for: [
            item("/lib/Support/com.apple.sharedfilelist/x/com.test.app.sfl4",
                 mechanism: "LocationInventorySource", tier: .B, bytes: 1,
                 sentence: "The list macOS keeps of documents this application opened."),
            item("/lib/Caches/com.test.app", mechanism: "LocationInventorySource",
                 tier: .B, bytes: 1, sentence: "A cache folder keyed to the bundle identifier."),
            item("/lib/HTTPStorages/com.test.app", mechanism: "LocationInventorySource",
                 tier: .B, bytes: 1, sentence: "Cookies and web storage macOS keeps."),
        ])

        for group in found {
            for row in group.items {
                XCTAssertEqual(
                    row.evidence.humanSentence, group.explanation,
                    "\(row.evidence.url.lastPathComponent) sits under a heading that says "
                    + "\"\(group.explanation)\", which is not what Brim knows about it."
                )
            }
        }
        XCTAssertEqual(found.count, 3, "Three different reasons are three groups.")
    }

    /// **Also seen in the running app.** "Named after the application rather
    /// than its identifier, so Brim will not tick it for you" was labelled
    /// Strong, because the same source had found a Tier B preferences file
    /// and the label was the strongest tier in the group. A heading that
    /// says Brim will not tick something, beside a label that means Brim
    /// will, is the kind of contradiction that gets a person to stop reading
    /// the headings.
    func testAGroupNeverMixesTiers() async {
        let found = await groups(for: [
            item("/lib/Support/Code", mechanism: "BundleIdentifierComponentSource", tier: .C,
                 bytes: 131_500_000,
                 sentence: "Named after the application rather than its identifier, so Brim "
                    + "will not tick it for you."),
            item("/lib/Preferences/com.test.app.plist", mechanism: "BundleIdentifierComponentSource",
                 tier: .B, bytes: 1_000, sentence: "Preferences keyed to the bundle identifier"),
        ])

        for group in found {
            for row in group.items {
                XCTAssertEqual(
                    row.evidence.tier, group.strongestTier,
                    "A \(row.evidence.tier.rawValue) row is labelled "
                    + "\(group.strongestTier.shortLabel) because it shares a group with "
                    + "stronger evidence."
                )
            }
        }
        let nameMatch = found.first { $0.items.contains { $0.evidence.url.path == "/lib/Support/Code" } }
        XCTAssertEqual(nameMatch?.strongestTier.shortLabel, "Heuristic")
    }

    /// The same reason at the same strength from two different sources is
    /// one thing to the person reading it. Which part of Brim noticed is not
    /// something they reason about.
    func testTheSameReasonFromTwoSourcesIsOneGroup() async {
        let found = await groups(for: [
            item("/lib/Caches/com.test.app", mechanism: "BundleIdentifierStateSource",
                 tier: .B, bytes: 10, sentence: "A cache folder keyed to the bundle identifier."),
            item("/lib/Caches/com.test.app.ShipIt", mechanism: "LocationInventorySource",
                 tier: .B, bytes: 20, sentence: "A cache folder keyed to the bundle identifier."),
        ])

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.totalBytes, 30)
        XCTAssertEqual(Set(found.map(\.id)).count, found.count, "Group identities collide.")
    }

    /// A row the engine gave no sentence still gets a heading, and two
    /// sources with nothing to say are not merged under one of their names.
    func testRowsWithoutASentenceAreNotMergedAcrossSources() async {
        let found = await groups(for: [
            item("/x", mechanism: "OneSource", tier: .B, bytes: 1, sentence: ""),
            item("/y", mechanism: "AnotherSource", tier: .B, bytes: 1, sentence: ""),
        ])

        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.mechanism)), ["OneSource", "AnotherSource"])
        XCTAssertEqual(Set(found.map(\.id)).count, 2, "Group identities collide.")
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
            func leftovers() async throws -> [Leftover] { [] }
            func recoverableItems() async throws -> [RecoverableItem] { [] }
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
    func leftovers() async throws -> [Leftover] { [] }
    func recoverableItems() async throws -> [RecoverableItem] { [] }
}

private enum Nope: Error { case no }
