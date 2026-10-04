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
                 tier: .B, bytes: 1, sentence: "Cookies and web storage macOS keeps.")
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
                 tier: .B, bytes: 1000, sentence: "Preferences keyed to the bundle identifier")
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
                 tier: .B, bytes: 20, sentence: "A cache folder keyed to the bundle identifier.")
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
            item("/y", mechanism: "AnotherSource", tier: .B, bytes: 1, sentence: "")
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
        let model = ApplicationsModel()
        await model.load(service: FailingAppsService())

        XCTAssertTrue(model.applications.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }
}
