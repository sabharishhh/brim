import BrimCore
@testable import BrimScan
import XCTest

/// Reading Background Task Management straight from its store, with no
/// prompt and no tool.
final class BTMStoreTests: XCTestCase {
    private static let thisUser = UUID(uuidString: "C995F5A3-ED44-45EF-B512-E97AEBAFDE8A")!
    private var thisUser: UUID {
        Self.thisUser
    }

    // MARK: - Which files to read

    func testOnlyTheNewestVersionIsRead() {
        // An older format version stays on disk after an upgrade and lists removed
        // software; reading it would report false leftovers.
        let files = [
            "BackgroundItems-v16.btm",
            "BackgroundItems-v18.btm",
            "BackgroundItems-v18-C995F5A3-ED44-45EF-B512-E97AEBAFDE8A.btm"
        ].map { URL(fileURLWithPath: "/var/db/com.apple.backgroundtaskmanagement/\($0)") }

        let chosen = BTMStore.storesToRead(in: files, belongingTo: thisUser)

        XCTAssertEqual(chosen.map(\.lastPathComponent),
                       ["BackgroundItems-v18-C995F5A3-ED44-45EF-B512-E97AEBAFDE8A.btm"])
    }

    func testAnotherAccountsItemsAreLeftAlone() {
        // Their login items are not this person's to see or to remove.
        let files = [
            "BackgroundItems-v18-C995F5A3-ED44-45EF-B512-E97AEBAFDE8A.btm",
            "BackgroundItems-v18-11111111-2222-3333-4444-555555555555.btm"
        ].map { URL(fileURLWithPath: "/tmp/\($0)") }

        let chosen = BTMStore.storesToRead(in: files, belongingTo: thisUser)

        XCTAssertEqual(chosen.count, 1)
        XCTAssertTrue(chosen[0].lastPathComponent.contains("C995F5A3"))
    }

    func testSystemAccountsAreRead() {
        // `FFFFEEEE-DDDD-CCCC-BBBB-AAAA...` names are system pseudo-accounts, not
        // people; uid 0's holds machine-wide daemons.
        let files = [
            "BackgroundItems-v18-FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000.btm",
            "BackgroundItems-v18-C995F5A3-ED44-45EF-B512-E97AEBAFDE8A.btm"
        ].map { URL(fileURLWithPath: "/tmp/\($0)") }

        XCTAssertEqual(BTMStore.storesToRead(in: files, belongingTo: thisUser).count, 2)
    }

    func testTheIndexFileIsNotMistakenForAStore() {
        let files = [URL(fileURLWithPath: "/tmp/BackgroundItems-v18.btm")]
        XCTAssertTrue(BTMStore.storesToRead(in: files, belongingTo: thisUser).isEmpty)
    }

    func testNamesAreReadAsVersionAndAccount() {
        XCTAssertEqual(BTMStore.parseName("BackgroundItems-v18.btm")?.version, 18)
        XCTAssertNil(BTMStore.parseName("BackgroundItems-v18.btm")?.owner)
        XCTAssertEqual(BTMStore.parseName("BackgroundItems-v7-ABC.btm")?.owner, "ABC")
        XCTAssertNil(BTMStore.parseName("something-else.btm"))
        XCTAssertNil(BTMStore.parseName("BackgroundItems-v18.plist"))
    }

    // MARK: - Decoding

    func testRecordsComeBackOutOfAnArchive() throws {
        let directory = try makeStore(items: [
            FixtureItem(
                name: "Sample", developerName: "Example Developer",
                bundleIdentifier: "com.example.Sample",
                identifier: "2.com.example.Sample",
                container: nil,
                url: URL(string: "file:///Applications/Sample.app/"),
                type: 0x2, disposition: 0x3
            )
        ])

        let records = try XCTUnwrap(BTMStore(directory: directory, currentUser: { Self.thisUser }).records())

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].name, "Sample")
        XCTAssertEqual(records[0].developerName, "Example Developer")
        XCTAssertEqual(records[0].bundleIdentifier, "com.example.Sample")
        XCTAssertEqual(records[0].identifier, "2.com.example.Sample")
        XCTAssertEqual(records[0].rawURLPath, "/Applications/Sample.app")
        XCTAssertEqual(records[0].type, "app")
        XCTAssertEqual(records[0].disposition, "on, allowed")
    }

    func testAnEmbeddedItemKeepsItsPathRelative() throws {
        // An embedded helper is a relative URL against `file:///`; its `path` would
        // be a file at the root of the disk.
        let directory = try makeStore(items: [
            FixtureItem(
                name: "Sample Helper", developerName: nil,
                bundleIdentifier: "com.example.Sample-Helper",
                identifier: "4.com.example.Sample-Helper",
                container: "2.com.example.Sample",
                url: URL(string: "Contents/Library/LoginItems/Sample%20Helper.app",
                         relativeTo: URL(string: "file:///")),
                type: 0x4, disposition: 0x9
            )
        ])

        let records = try XCTUnwrap(BTMStore(directory: directory, currentUser: { Self.thisUser }).records())

        XCTAssertEqual(records[0].rawURLPath, "Contents/Library/LoginItems/Sample Helper.app")
        XCTAssertTrue(records[0].hasRelativeURL)
        XCTAssertEqual(records[0].parentIdentifier, "2.com.example.Sample")
    }

    func testAnUnreadableStoreIsNotAnEmptyOne() {
        // Without Full Disk Access, the answer is "did not look", not "nothing
        // found".
        let nowhere = URL(fileURLWithPath: "/var/db/there-is-no-such-directory")
        XCTAssertNil(BTMStore(directory: nowhere, currentUser: { Self.thisUser }).records())
    }

    func testThisAccountHasADirectoryUUID() {
        // The store files are named for this UUID, which comes from the directory
        // service and cannot be faked in a fixture.
        XCTAssertNotNil(BTMStore.directoryUUID(for: getuid()))
    }

    // MARK: - Bit fields

    func testTypesAndDispositionsReadAsWords() {
        XCTAssertEqual(BTMDisposition.typeDescription(0x2), "app")
        XCTAssertEqual(BTMDisposition.typeDescription(0x4), "login item")
        XCTAssertEqual(BTMDisposition.typeDescription(0x2000), "background task")
        XCTAssertEqual(BTMDisposition.describe(0x0), "off")
        XCTAssertEqual(BTMDisposition.describe(0xB), "on, allowed, notified")
        XCTAssertTrue(BTMDisposition.isEnabled(0x9))
        XCTAssertFalse(BTMDisposition.isEnabled(0x2))
    }

    func testAnUnknownBitIsShownAsItsNumberRatherThanGuessedAt() {
        // A wrong label here is read as a fact about the user's Mac.
        XCTAssertEqual(BTMDisposition.typeDescription(0x400000), "type 0x400000")
        XCTAssertEqual(BTMDisposition.typeDescription(0x400002), "app (0x400002)")
    }

    func testReadableAccountDoesNotHideUnsupportedMachineArchive() throws {
        let directory = try makeStore(items: [])
        try Data("unsupported archive".utf8).write(to: directory.appendingPathComponent(
            "BackgroundItems-v18-FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000.btm"
        ))
        let snapshot = BTMStore(directory: directory, currentUser: { Self.thisUser }).snapshot()
        XCTAssertFalse(snapshot.coverage.available)
        XCTAssertEqual(snapshot.coverage.scopes?.filter(\.available).count, 1)
        XCTAssertEqual(snapshot.coverage.scopes?.filter { !$0.available }.count, 1)
    }

    func testAbsentMachineNamespaceIsNotCertifiedByEmptyAccountStore() throws {
        let directory = try makeStore(items: [])
        let snapshot = BTMStore(directory: directory, currentUser: { Self.thisUser }).snapshot()
        XCTAssertFalse(snapshot.coverage.available)
        XCTAssertTrue(snapshot.records.isEmpty)
    }

    // MARK: - Fixtures

    private func makeStore(items: [FixtureItem]) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("btm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("BTMUserStore", for: FixtureStore.self)
        archiver.setClassName("ItemRecord", for: FixtureItem.self)
        archiver.encode(FixtureStore(items: items), forKey: "userStore")
        archiver.finishEncoding()

        try archiver.encodedData.write(
            to: directory.appendingPathComponent("BackgroundItems-v18-\(thisUser.uuidString).btm")
        )
        return directory
    }
}

/// Writes the archive shape macOS writes, so the reader is tested against
/// what it will meet.
@objc(BrimFixtureStore)
private final class FixtureStore: NSObject, NSCoding {
    let items: [FixtureItem]
    init(items: [FixtureItem]) {
        self.items = items
    }

    init?(coder _: NSCoder) {
        items = []
    }

    func encode(with coder: NSCoder) {
        coder.encode(items, forKey: "records")
    }
}

@objc(BrimFixtureItem)
private final class FixtureItem: NSObject, NSCoding {
    let name: String?
    let developerName: String?
    let bundleIdentifier: String?
    let identifier: String?
    let container: String?
    let url: URL?
    let type: Int
    let disposition: Int

    init(
        name: String?, developerName: String?, bundleIdentifier: String?,
        identifier: String?, container: String?, url: URL?, type: Int, disposition: Int
    ) {
        self.name = name
        self.developerName = developerName
        self.bundleIdentifier = bundleIdentifier
        self.identifier = identifier
        self.container = container
        self.url = url
        self.type = type
        self.disposition = disposition
    }

    init?(coder _: NSCoder) {
        nil
    }

    func encode(with coder: NSCoder) {
        coder.encode(name, forKey: "name")
        coder.encode(developerName, forKey: "developerName")
        coder.encode(bundleIdentifier, forKey: "bundleIdentifier")
        coder.encode(identifier, forKey: "identifier")
        coder.encode(container, forKey: "container")
        coder.encode(url.map { $0 as NSURL }, forKey: "url")
        coder.encode(UUID() as NSUUID, forKey: "uuid")
        coder.encode(type, forKey: "type")
        coder.encode(disposition, forKey: "disposition")
    }
}
