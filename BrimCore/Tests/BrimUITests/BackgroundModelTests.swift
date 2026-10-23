import BrimCore
import BrimProtocol
@testable import BrimUI
import XCTest

/// Picking background jobs for removal. A launchd job is a file and can be
/// taken away; a background item is a row in a database macOS owns, and
/// offering a per-item removal would promise what cannot be delivered.
@MainActor
final class BackgroundSelectionTests: XCTestCase {
    private func job(_ label: String, record: String, exists: Bool = false) -> Registration {
        Registration(
            kind: .launchdJob, identifier: label, label: label, owningBundleID: label,
            programPath: nil, targetExists: exists, recordPath: record, evidence: "because"
        )
    }

    private func backgroundItem(_ label: String, exists: Bool = false) -> Registration {
        Registration(
            kind: .backgroundItem, identifier: label, label: label, owningBundleID: label,
            programPath: "/Applications/\(label).app", targetExists: exists,
            recordPath: nil, evidence: "because"
        )
    }

    func testOnlyJobFilesCanBePickedForRemoval() {
        XCTAssertTrue(BackgroundModel.isRemovable(
            job("com.google.keystone.agent", record: "/Library/LaunchAgents/x.plist")
        ))
        XCTAssertFalse(BackgroundModel.isRemovable(backgroundItem("Sample")),
                       "macOS owns that database and offers no way to remove one row")
    }

    func testASystemJobIsNeverOffered() {
        let apple = Registration(
            kind: .launchdJob, identifier: "com.apple.thing", label: "com.apple.thing",
            targetExists: false, recordPath: "/System/Library/LaunchDaemons/x.plist",
            evidence: "because", isSystemOwned: true
        )
        XCTAssertFalse(BackgroundModel.isRemovable(apple))
    }

    func testPickingAGroupPicksEveryFileUnderIt() {
        // The same job in both domains: ticking the app means both copies.
        let model = BackgroundModel()
        let group = RegistrationGroup.group([
            job("com.google.keystone.agent", record: "/Users/me/Library/LaunchAgents/a.plist"),
            job("com.google.keystone.agent", record: "/Library/LaunchAgents/a.plist")
        ])[0]

        model.toggle(group)

        XCTAssertEqual(model.selection.count, 2)
        XCTAssertTrue(model.isSelected(group))
        model.toggle(group)
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testAGroupWithNothingRemovableCannotBePicked() {
        let model = BackgroundModel()
        let group = RegistrationGroup.group([backgroundItem("Sample")])[0]
        XCTAssertFalse(model.canSelect(group))
    }

    func testTheIntentNamesThePlistsAndNotTheJobLabels() {
        // The planner works from paths; a label is not a file.
        let model = BackgroundModel()
        let group = RegistrationGroup.group([
            job("com.google.keystone.agent", record: "/Library/LaunchAgents/a.plist")
        ])[0]
        model.toggle(group)

        // Nothing is selectable until a report is loaded.
        XCTAssertNil(model.removalIntent(requesterIdentity: "tester"),
                     "A selection with no loaded report names nothing")
    }
}

private actor RegistrationStub: BrimServiceProtocol {
    let report: RegistrationReport
    let applications: [InstalledApplication]
    let inventoryUnavailable: Bool
    init(
        _ registrations: [Registration], applications: [InstalledApplication] = [], inventoryUnavailable: Bool = false
    ) {
        report = RegistrationReport(registrations: registrations, coverage: [])
        self.applications = applications
        self.inventoryUnavailable = inventoryUnavailable
    }

    func registrations() async -> RegistrationReport {
        report
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw Nope.no
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw Nope.no
    }

    func requestApproval(
        planId _: UUID, requesterIdentity _: String
    ) async throws -> ApprovalRequestReceipt {
        throw Nope.no
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw Nope.no
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw Nope.no
    }

    func history() async throws -> [Plan] {
        []
    }

    func undo(planId _: UUID) async throws {
        throw Nope.no
    }

    func installedApplications() async throws -> [InstalledApplication] {
        if inventoryUnavailable {
            throw Nope.no
        }
        return applications
    }

    func leftovers() async throws -> [Leftover] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }
}

private enum Nope: Error { case no }

/// The Background list is software somebody installed. Apple's own
/// registrations are left out; none of them can be removed.
@MainActor
final class BackgroundScopeTests: XCTestCase {
    private func extensionOf(_ label: String, path: String, macOS: Bool) -> Registration {
        Registration(
            kind: .appExtension, identifier: label, label: label, owningBundleID: label,
            programPath: path, targetExists: true, evidence: "because", isSystemOwned: macOS
        )
    }

    private func load(_ registrations: [Registration]) async -> BackgroundModel {
        let model = BackgroundModel()
        await model.load(service: RegistrationStub(registrations))
        return model
    }

    func testUnrelatedEntriesStayInTheReportButCannotEnterThePageSelection() async {
        // System firewall executables and raw shell lines identify no application.
        let job = Registration(
            kind: .launchdJob, identifier: "com.example.unclaimed", label: "Unclaimed",
            programPath: "/usr/local/bin/tool", targetExists: false,
            recordPath: "/Library/LaunchAgents/com.example.unclaimed.plist", evidence: "fixture"
        )
        let records = [job,
                       Registration(kind: .firewallEntry, identifier: "/usr/sbin/cupsd", label: "cupsd",
                                    programPath: "/usr/sbin/cupsd", targetExists: true, evidence: "fixture"),
                       Registration(kind: .shellProfileLine, identifier: "line", label: "export PATH",
                                    programPath: "/Applications/Sample.app/tool", targetExists: false,
                                    evidence: "fixture"),
                       Registration(kind: .backgroundItem, identifier: "com.example.removed", label: "Removed",
                                    programPath: "/Applications/Removed.app", targetExists: false, evidence: "fixture")]
        let model = await load(records)
        XCTAssertEqual(model.report.registrations, records)
        XCTAssertEqual(model.live.map(\.displayName), ["Removed"])
        XCTAssertTrue(model.stale.isEmpty)
        model.selection = [job.id]
        XCTAssertTrue(model.selectedItems.isEmpty)
        XCTAssertNil(model.removalIntent(requesterIdentity: "fixture"))
    }

    func testAnUnavailableApplicationInventoryStillShowsRecordedAppPaths() async {
        let record = extensionOf(
            "Sample Extension", path: "/Users/me/Apps/Sample.app/Contents/PlugIns/a.appex", macOS: false
        )
        let model = BackgroundModel()
        await model.load(service: RegistrationStub([record], inventoryUnavailable: true))
        XCTAssertEqual(model.live.map(\.displayName), ["Sample"])
    }

    func testMacOSsOwnRegistrationsAreNotInTheList() async {
        let model = await load([
            extensionOf("AVConference", path: "/System/Library/x.appex", macOS: true),
            extensionOf("AppIntents", path: "/System/Library/y.appex", macOS: true),
            extensionOf("OpenInIINA", path: "/Applications/IINA.app/z.appex", macOS: false)
        ])

        XCTAssertEqual(model.live.map(\.displayName), ["IINA"])
    }

    /// The line is who owns the registration, not who wrote the software: an
    /// Apple app from the App Store is somebody's installed app.
    func testAnInstalledApplicationIsShownWhoeverWroteIt() async {
        let model = await load([
            extensionOf(
                "Developer Widget",
                path: "/Applications/Developer.app/Contents/PlugIns/Developer Widget.appex",
                macOS: false
            )
        ])
        XCTAssertEqual(model.live.map(\.displayName), ["Developer"])
    }

    func testTheSearchNarrowsTheList() async {
        let model = await load([
            extensionOf("OpenInIINA", path: "/Applications/IINA.app/z.appex", macOS: false),
            extensionOf("Intents", path: "/Applications/WhatsApp.app/i.appex", macOS: false)
        ])
        XCTAssertEqual(model.live.count, 2)

        model.searchText = "iina"
        XCTAssertEqual(model.live.map(\.displayName), ["IINA"],
                       "The lists are held rather than computed, so a keystroke has to update them")

        model.searchText = ""
        XCTAssertEqual(model.live.count, 2)
    }

    /// The lists are stored, not recomputed on every read of a body pass.
    func testReadingTheListTwiceGivesTheSameArrayBack() async {
        let model = await load([
            extensionOf("OpenInIINA", path: "/Applications/IINA.app/z.appex", macOS: false)
        ])

        var first = model.live
        let second = model.live
        XCTAssertEqual(first, second)
        // Arrays are values: mutating a copy must not reach the model.
        first.removeAll()
        XCTAssertEqual(model.live.count, 1)
    }
}
