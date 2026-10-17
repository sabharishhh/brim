import XCTest
@testable import BrimService

/// Presence within one launch, and the grace window's limits.
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

        // A second store over the same directory is what the next launch sees.
        let next = PresenceStore(directoryURL: directory)
        let enrolled = await next.isEnrolled
        XCTAssertTrue(enrolled, "Setup must happen once, not once per launch")
    }

    /// The grace window is never read back from disk: any program the person
    /// runs could write a time there and skip the fingerprint.
    func testPresenceDoesNotSurviveARelaunch() async throws {
        await PresenceStore(directoryURL: directory).recordEnrolment()
        let forged = #"{"enrolledAt":800000000,"lastPresence":\#(Date().timeIntervalSinceReferenceDate)}"#
        try Data(forged.utf8).write(to: directory.appendingPathComponent("presence.json"))

        let next = PresenceStore(directoryURL: directory)
        let presence = await next.lastPresence
        let enrolled = await next.isEnrolled
        XCTAssertNil(presence, "A time read from the disk stood in for a fingerprint")
        XCTAssertTrue(enrolled)
    }

    func testEnrolmentCountsAsPresence() async {
        // Confirming at the welcome screen counts as presence.
        let store = PresenceStore(directoryURL: directory)
        await store.recordEnrolment()
        let presence = await store.lastPresence
        XCTAssertNotNil(presence)
    }

    func testATimestampInTheFutureIsIgnored() async {
        // A clock moved backwards must not satisfy the window indefinitely.
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
