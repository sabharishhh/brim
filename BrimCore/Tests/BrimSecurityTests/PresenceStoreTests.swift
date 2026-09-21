import XCTest
@testable import BrimService

/// Presence has to survive a relaunch, or the first destructive action of
/// every session costs a fingerprint — which during a build-and-test loop is
/// most of them, and is what made this tiring enough to complain about.
final class PresenceStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimPresence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAFreshMachineHasNotEnrolled() async {
        let store = PresenceStore(directoryURL: directory)
        let enrolled = await store.isEnrolled
        let presence = await store.lastPresence
        XCTAssertFalse(enrolled)
        XCTAssertNil(presence)
    }

    func testEnrolmentSurvivesARelaunch() async {
        await PresenceStore(directoryURL: directory).recordEnrolment()

        // A second store over the same directory is what the next launch
        // sees.
        let next = PresenceStore(directoryURL: directory)
        let enrolled = await next.isEnrolled
        XCTAssertTrue(enrolled, "Setup must happen once, not once per launch")
    }

    func testPresenceSurvivesARelaunch() async {
        await PresenceStore(directoryURL: directory).recordPresence()

        let next = PresenceStore(directoryURL: directory)
        let presence = await next.lastPresence
        XCTAssertNotNil(
            presence,
            "Quitting and reopening Brim is not by itself a reason to ask again"
        )
    }

    func testEnrolmentCountsAsPresence() async {
        // Someone who has just confirmed at the welcome screen has plainly
        // proved they are here; asking again a second later would be absurd.
        let store = PresenceStore(directoryURL: directory)
        await store.recordEnrolment()
        let presence = await store.lastPresence
        XCTAssertNotNil(presence)
    }

    func testATimestampInTheFutureIsIgnored() async {
        // A clock moved backwards would otherwise leave a record that
        // satisfies the grace window indefinitely.
        let store = PresenceStore(directoryURL: directory)
        await store.recordPresence(at: Date().addingTimeInterval(3600))
        let presence = await store.lastPresence
        XCTAssertNil(presence)
    }

    func testPresenceCanBeForgottenWithoutUndoingEnrolment() async {
        let store = PresenceStore(directoryURL: directory)
        await store.recordEnrolment()
        await store.forgetPresence()

        let enrolled = await store.isEnrolled
        let presence = await store.lastPresence
        XCTAssertTrue(enrolled, "Setup is not undone by asking to confirm again")
        XCTAssertNil(presence)
    }

    func testACorruptRecordDoesNotPreventStartup() async {
        try? "not json".write(
            to: directory.appendingPathComponent("presence.json"),
            atomically: true, encoding: .utf8
        )
        let store = PresenceStore(directoryURL: directory)
        let enrolled = await store.isEnrolled
        XCTAssertFalse(enrolled, "Unreadable means unknown, which costs one prompt and nothing else")
    }
}
