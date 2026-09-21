import XCTest
import BrimCore
@testable import BrimScan

/// Signing state on a background item, which T-3.8 asks for and which the
/// store had been carrying unread all along.
///
/// The finding worth having is not "this is signed". It is that macOS
/// recorded one team when it agreed to run the item and the code sitting
/// there now is signed by another, which System Settings does not show
/// anywhere.
final class SigningStateTests: XCTestCase {

    func testATeamThatChangedUnderMacOSIsTheFinding() {
        let state = SigningState.teamChanged(recorded: "X85ZX835W9", found: "AAAA111111")
        XCTAssertTrue(state.isTrouble)
        XCTAssertTrue(state.sentence.contains("X85ZX835W9"))
        XCTAssertTrue(state.sentence.contains("AAAA111111"))
    }

    func testAnUnexaminedItemIsNotAVerdict() {
        // "Did not look" is not "found something wrong", the same rule
        // coverage exists for.
        XCTAssertFalse(SigningState.notChecked("No code here.").isTrouble)
        XCTAssertFalse(SigningState.valid(team: "X85ZX835W9").isTrouble)
    }

    func testSomethingThatIsNotCodeIsReportedAsUnexamined() {
        let nowhere = URL(fileURLWithPath: "/var/db/there-is-no-such-thing")
        let state = CodeSignature.state(of: nowhere, recordedTeam: nil)
        guard case .notChecked = state else {
            return XCTFail("A path with no code is not a signing verdict, got \(state)")
        }
    }

    func testARealApplicationChecksOut() throws {
        // Finder is always there and always signed by Apple. If this fails
        // the checker is wrong, not the Mac.
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: finder.path))

        guard case .valid = CodeSignature.state(of: finder, recordedTeam: nil) else {
            return XCTFail("Finder should validate")
        }
    }

    func testAGroupShowsOneTeamOnlyWhenEverythingCheckedAgrees() {
        func item(_ label: String, _ signing: SigningState?) -> Registration {
            Registration(kind: .backgroundItem, identifier: label, label: label,
                         owningBundleID: "com.vendor.app", targetExists: true,
                         evidence: "because", signing: signing)
        }

        // A pathless background-tasks record sits beside its application
        // and must not suppress the team.
        let agreed = RegistrationGroup.group([
            item("App", .valid(team: "TEAM1")), item("App - background tasks", nil)
        ])
        XCTAssertEqual(agreed[0].signedBy, "TEAM1")

        let disagreed = RegistrationGroup.group([
            item("App", .valid(team: "TEAM1")), item("Helper", .valid(team: "TEAM2"))
        ])
        XCTAssertNil(disagreed[0].signedBy)

        let suspect = RegistrationGroup.group([
            item("App", .valid(team: "TEAM1")), item("Helper", .unsigned)
        ])
        XCTAssertNil(suspect[0].signedBy, "One unsigned helper is not a signed application")
    }
}
