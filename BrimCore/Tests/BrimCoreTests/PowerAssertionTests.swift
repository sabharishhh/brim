import XCTest
@testable import BrimCore

/// What is holding sleep off. The person's apps come first; assertions
/// macOS holds because the screen is on or audio is routed follow from them
/// and are not listed as equals.
final class PowerAssertionTests: XCTestCase {

    private typealias Held = PowerAssertions.Held

    private func held(
        _ owner: String, _ kind: PowerAssertions.Kind,
        reason: String? = nil, isYours: Bool = true, pid: Int32 = 1
    ) -> Held {
        Held(pid: pid, owner: owner, bundlePath: nil, kind: kind, reason: reason, isYours: isYours)
    }

    // MARK: - Reading the assertion types

    func testTheTypesThatMeanTheMacStaysAwake() {
        for type in ["PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep"] {
            XCTAssertEqual(PowerAssertions.Kind.of(type), .systemAwake, type)
        }
    }

    func testTheTypesThatMeanTheScreenStaysOn() {
        for type in ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"] {
            XCTAssertEqual(PowerAssertions.Kind.of(type), .displayAwake, type)
        }
    }

    /// Bookkeeping types such as `UserIsActive` are not reported.
    func testBookkeepingTypesAreNotReported() {
        for type in ["UserIsActive", "InternalPreventDisplaySleep", "ApplePushServiceTask", ""] {
            XCTAssertNil(PowerAssertions.Kind.of(type), type)
        }
    }

    // MARK: - What the sentence says

    func testTheSentenceNamesWhatThePersonCanActOn() {
        let assertions = PowerAssertions(
            held: [
                held("Claude", .systemAwake, reason: "Electron"),
                held("Power management", .systemAwake,
                     reason: "Powerd - Prevent sleep while display is on", isYours: false),
                held("Audio engine", .systemAwake, isYours: false)
            ],
            wasRead: true
        )

        let sentence = assertions.sentence ?? ""
        XCTAssertTrue(sentence.contains("Claude"), sentence)
        XCTAssertFalse(
            sentence.contains("Power management"),
            "macOS holds one whenever the screen is on. Naming it beside Claude sends "
            + "somebody after the wrong thing: \(sentence)"
        )
    }

    func testTwoOfYoursAreNamedTogether() {
        let assertions = PowerAssertions(
            held: [held("Music", .systemAwake), held("Claude", .systemAwake)],
            wasRead: true
        )
        XCTAssertEqual(
            assertions.sentence,
            "Music and Claude are keeping this Mac awake, so it will not sleep on its own."
        )
    }

    /// When only macOS holds one, that is still said.
    func testMacOSAloneIsStillReported() {
        let assertions = PowerAssertions(
            held: [held("Audio engine", .systemAwake, isYours: false)], wasRead: true
        )
        XCTAssertTrue(assertions.sentence?.contains("Audio engine") ?? false)
    }

    func testTheScreenStayingOnIsSaidDifferentlyFromTheMacStayingAwake() {
        let display = PowerAssertions(held: [held("Safari", .displayAwake)], wasRead: true)
        XCTAssertTrue(display.sentence?.contains("keeping the screen on") ?? false,
                      display.sentence ?? "nil")
    }

    // MARK: - Nothing found is not the same as did not look

    func testNothingHoldingItAwakeSaysNothing() {
        XCTAssertNil(PowerAssertions(held: [], wasRead: true).sentence)
    }

    func testAFailedReadIsNotReportedAsAQuietMac() {
        // A read that did not happen has no rows, and `wasRead` tells it apart from
        // nothing held.
        XCTAssertFalse(PowerAssertions.notRead.wasRead)
        XCTAssertNil(PowerAssertions.notRead.sentence)
    }

    // MARK: - Ordering

    func testWhatAPersonCanActOnComesFirst() {
        let ordered = [
            held("Power management", .systemAwake, isYours: false),
            held("Claude", .displayAwake)
        ].sorted { left, right in
            if left.isYours != right.isYours { return left.isYours }
            if left.kind != right.kind { return left.kind == .systemAwake }
            return left.owner < right.owner
        }
        XCTAssertEqual(ordered.first?.owner, "Claude")
    }

    // MARK: - Against the real machine

    func testTheRealReadEitherWorksOrSaysItDidNot() {
        // Checks the call is wired up, not what is held, so a failed read does not
        // look like a Mac with nothing keeping it awake.
        let assertions = PowerAssertions.current()
        XCTAssertTrue(assertions.wasRead, "IOPMCopyAssertionsByProcess did not answer")
        for one in assertions.held {
            XCTAssertFalse(one.owner.isEmpty, "An assertion with no owner tells nobody anything")
        }
    }
}
