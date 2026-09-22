import XCTest
@testable import BrimCore

/// What is holding sleep off, which is the thing nothing else says plainly.
///
/// System Settings shows a charge graph and a line reading "No Apps Using
/// Significant Energy". Activity Monitor has a Preventing Sleep column that
/// answers Yes or No. Neither names the assertion, says which kind of sleep
/// is being held, or separates the software that asked from the macOS
/// services that follow on behind it.
///
/// Read from this Mac while writing these tests, which is where the shape of
/// the problem came from:
///
///     Music    PreventUserIdleSystemSleep  com.apple.Music.playback
///     Claude   NoIdleSleepAssertion        Electron
///     powerd   PreventUserIdleSystemSleep  Powerd - Prevent sleep while display is on
///     coreaudiod PreventUserIdleSystemSleep com.apple.audio…preventuseridlesleep
///
/// The first two are a person's to stop. The last two are macOS's own, held
/// because the screen is on and because audio is routed, which are
/// consequences of the first two rather than causes. Listing all four as
/// equals sends somebody after `powerd`.
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

    /// macOS defines a dozen assertion types and most are bookkeeping.
    /// `UserIsActive`, held by WindowServer every time the mouse moves, is
    /// the one that would otherwise fill this list on every single read.
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

    /// When only macOS is holding one there is still something worth saying,
    /// because the alternative is a card that appears with no sentence in it.
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
        // The distinction this product draws everywhere: a zero nobody
        // measured is a lie. A read that did not happen has no sentence and
        // no rows, and `wasRead` is what tells the two apart.
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
        // Not asserting anything is held: that depends on what is running.
        // Asserting the call is wired up correctly, so a silent failure to
        // read does not masquerade as a Mac with nothing holding it awake.
        let assertions = PowerAssertions.current()
        XCTAssertTrue(assertions.wasRead, "IOPMCopyAssertionsByProcess did not answer")
        for one in assertions.held {
            XCTAssertFalse(one.owner.isEmpty, "An assertion with no owner tells nobody anything")
        }
    }
}
