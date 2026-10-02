import BrimCore
@testable import BrimUI
import XCTest

/// Background is grouped by whether something should be running, and an
/// application with one dead job and one live one is two rows, not one.
final class BackgroundGroupingTests: XCTestCase {
    private func registration(
        _ kind: Registration.Kind, _ identifier: String, program: String? = nil, exists: Bool = true,
        atLogin: Bool? = nil
    ) -> Registration {
        Registration(
            kind: kind, identifier: identifier, label: identifier, owningBundleID: "com.example.app",
            programPath: program, targetExists: exists, evidence: "evidence", atLogin: atLogin
        )
    }

    @MainActor
    func testSharedBackgroundStoreIsNeverAFinderTarget() {
        // Teams and ChatGPT both revealed the same BTM archive beside their
        // individual paths, making a shared database look app-owned.
        let store = "/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v18-account.btm"
        let target = "/Applications/ChatGPT.app"
        let app = Registration(kind: .backgroundItem, identifier: "app", label: "App", programPath: target,
                               targetExists: true, recordPath: store, evidence: "")
        XCTAssertEqual(app.revealCandidatePaths, [target])
        let unresolved = Registration(kind: .backgroundItem, identifier: "missing", label: "Missing",
                                      targetExists: false, recordPath: store, evidence: "")
        XCTAssertTrue(unresolved.revealCandidatePaths.isEmpty)
        XCTAssertFalse(BackgroundModel.isRemovable(app))
    }

    func testDeadJobsComeFirstAndRetainedRecordsComeLastAndClosed() {
        let gone = RegistrationGroup(id: "a", displayName: "A", items: [registration(.launchdJob, "a", exists: false)])
        let tidying = RegistrationGroup(
            id: "b", displayName: "B", items: [registration(.backgroundItem, "b", exists: false)]
        )
        let login = RegistrationGroup(
            id: "c", displayName: "C", items: [registration(.backgroundItem, "c", atLogin: true)]
        )
        let agent = RegistrationGroup(id: "d", displayName: "D", items: [registration(.launchdJob, "d")])
        let grant = RegistrationGroup(id: "e", displayName: "E", items: [registration(.privacyGrant, "e")])

        let groups = BackgroundGrouper.groups(stale: [gone], clearing: [tidying], live: [grant, agent, login])

        XCTAssertEqual(groups.map(\.id), ["gone", "login", "background", "other", "clearing"])
        XCTAssertEqual(groups.last?.startsCollapsed, true)
    }

    /// Background Task Management keeps a record pointing at the bundle of
    /// every application with helpers. On this Mac that put Brim, ChatGPT
    /// and seven more under "Opens at login" when none of them did.
    func testPointingAtAnAppIsNotOpeningAtLogin() {
        let parent = RegistrationGroup(
            id: "p", displayName: "P", items: [registration(.backgroundItem, "p", program: "/Applications/P.app")]
        )
        let groups = BackgroundGrouper.groups(stale: [], clearing: [], live: [parent])
        XCTAssertEqual(groups.map(\.id), ["background"])
    }

    /// The model groups stale and live registrations separately, so one
    /// application can arrive in both. Keyed on the group alone, SwiftUI saw
    /// one identity in two places and the inspector could not tell which
    /// row was selected.
    func testTheSameApplicationInTwoListsIsTwoEntries() {
        let stale = RegistrationGroup(
            id: "x", displayName: "X", items: [registration(.launchdJob, "x1", exists: false)]
        )
        let live = RegistrationGroup(id: "x", displayName: "X", items: [registration(.launchdJob, "x2")])

        let ids = BackgroundGrouper.groups(stale: [stale], clearing: [], live: [live]).flatMap(\.items).map(\.id)

        XCTAssertEqual(Set(ids).count, 2)
    }

    func testMissingReportOnlyRecordsStayVisibleWithoutAPromiseToCollect() {
        let record = registration(.backgroundItem, "missing", exists: false)
        let report = RegistrationReport(registrations: [record], coverage: [])
        XCTAssertTrue(report.stale.isEmpty)
        XCTAssertEqual(report.live, [record])
        let group = RegistrationGroup(id: "missing", displayName: "Missing", items: [record])
        let sections = BackgroundGrouper.groups(stale: [], clearing: [], live: [group])
        XCTAssertEqual(sections.first?.title, "Still listed")
        XCTAssertFalse(record.isClearedByMacOS)
    }
}
