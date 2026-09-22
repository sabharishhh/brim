import XCTest
import BrimCore
import BrimProtocol
@testable import BrimUI

/// Picking background jobs for removal.
///
/// The rule worth protecting is what Brim refuses to offer. A launchd job
/// is a file and can be taken away. A background item is a row in a
/// database macOS owns, and the only tool it offers resets every
/// application's items at once, so offering a per item removal would be
/// promising something that cannot be delivered.
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
        XCTAssertFalse(BackgroundModel.isRemovable(backgroundItem("AppCleaner")),
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
        // Keystone installs the same job twice, once per domain. Ticking
        // the application means both copies, or the user removes one and
        // the other goes on sitting there.
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
        let group = RegistrationGroup.group([backgroundItem("AppCleaner")])[0]
        XCTAssertFalse(model.canSelect(group))
    }

    func testTheIntentNamesThePlistsAndNotTheJobLabels() {
        // The planner works from paths. A label is not a file, and naming
        // one would produce a plan that removes nothing.
        let model = BackgroundModel()
        let group = RegistrationGroup.group([
            job("com.google.keystone.agent", record: "/Library/LaunchAgents/a.plist")
        ])[0]
        model.toggle(group)

        // Nothing is selectable until a report has been loaded, since the
        // selection is resolved against it.
        XCTAssertNil(model.removalIntent(requesterIdentity: "tester"),
                     "A selection with no loaded report names nothing")
    }
}

private actor RegistrationStub: BrimServiceProtocol {
    let report: RegistrationReport
    init(_ registrations: [Registration]) {
        self.report = RegistrationReport(registrations: registrations, coverage: [])
    }
    func registrations() async -> RegistrationReport { report }

    func inspect(identity: Identity) async throws -> Footprint { throw Nope.no }
    func plan(intent: PlanIntent) async throws -> Plan { throw Nope.no }
    func explain(planId: UUID) async throws -> String { throw Nope.no }
    func requestApproval(
        planId: UUID, requesterIdentity: String
    ) async throws -> ApprovalRequestReceipt { throw Nope.no }
    func apply(planId: UUID, token: ApprovalToken) async throws { throw Nope.no }
    func verify(planId: UUID) async throws -> VerificationResult { throw Nope.no }
    func history() async throws -> [Plan] { [] }
    func undo(planId: UUID) async throws { throw Nope.no }
    func installedApplications() async throws -> [InstalledApplication] { [] }
    func leftovers() async throws -> [Leftover] { [] }
    func recoverableItems() async throws -> [RecoverableItem] { [] }
}

private enum Nope: Error { case no }

/// What the Background section is a list of.
///
/// It is a list of the software somebody installed. It used to carry a
/// switch called "Include macOS" that added Apple's own registrations, and
/// on a real Mac that meant 1,398 extra rows against 23 real ones: 905
/// launchd jobs, every one of them Apple's, and 484 of the 490 app
/// extensions. Nothing in that list could be removed, and turning the switch
/// on beachballed the window for several seconds and then drew a table of
/// `AccessibilitySettingsSearchExtension` and `AVConference`.
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

    func testMacOSsOwnRegistrationsAreNotInTheList() async {
        let model = await load([
            extensionOf("AVConference", path: "/System/Library/x.appex", macOS: true),
            extensionOf("AppIntents", path: "/System/Library/y.appex", macOS: true),
            extensionOf("OpenInIINA", path: "/Applications/IINA.app/z.appex", macOS: false),
        ])

        XCTAssertEqual(model.live.map(\.displayName), ["IINA"])
    }

    /// An Apple application somebody installed is still an application. The
    /// line is who owns the registration, not who wrote the software: Apple's
    /// Developer app from the App Store registers a widget under
    /// `developer.apple.wwdc-Release`, and that is somebody's installed app.
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
            extensionOf("Intents", path: "/Applications/WhatsApp.app/i.appex", macOS: false),
        ])
        XCTAssertEqual(model.live.count, 2)

        model.searchText = "iina"
        XCTAssertEqual(model.live.map(\.displayName), ["IINA"],
                       "The lists are held rather than computed, so a keystroke has to update them")

        model.searchText = ""
        XCTAssertEqual(model.live.count, 2)
    }

    /// The other half of the freeze. The three lists were computed
    /// properties, and one SwiftUI body pass reads `live` four times and
    /// `stale` three: each read filtered every registration and regrouped
    /// the survivors, 12ms a time and 73ms a pass on a real report, for an
    /// answer that had not changed between the first read and the seventh.
    /// Reading twice must not do the work twice.
    func testReadingTheListTwiceGivesTheSameArrayBack() async {
        let model = await load([
            extensionOf("OpenInIINA", path: "/Applications/IINA.app/z.appex", macOS: false)
        ])

        var first = model.live
        let second = model.live
        XCTAssertEqual(first, second)
        // Mutating one copy must not have reached into the model, which is
        // the thing a stored array gets wrong when it is handed out by
        // reference. Swift's arrays are values, and this says so out loud.
        first.removeAll()
        XCTAssertEqual(model.live.count, 1)
    }
}
