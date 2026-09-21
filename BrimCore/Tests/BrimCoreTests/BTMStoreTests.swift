import XCTest
import BrimCore
@testable import BrimScan

/// Reading Background Task Management without asking anybody for anything.
///
/// The prompt this replaces was the longest running annoyance in the app:
/// "Allow administrator access for sfltool?", once when the section loaded
/// and again on every rescan. The store behind that tool is a set of
/// ordinary files, so these tests are about reading them correctly rather
/// than about avoiding the prompt, which is avoided by not running the
/// tool at all.
final class BTMStoreTests: XCTestCase {

    private static let thisUser = UUID(uuidString: "C995F5A3-ED44-45EF-B512-E97AEBAFDE8A")!
    private var thisUser: UUID { Self.thisUser }

    // MARK: - Which files to read

    func testOnlyTheNewestVersionIsRead() {
        // A v16 file from a previous macOS is still on this Mac, last
        // written in September, and it lists software that has been removed
        // since. Reading it alongside v18 would report every one of those
        // as a leftover.
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
        // FFFFEEEE-DDDD-CCCC-BBBB-AAAA… is not a person. macOS mints one per
        // pseudo-account, and the one for uid 0 holds machine-wide daemons.
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
                name: "AppCleaner", developerName: "Julien Ramseier",
                bundleIdentifier: "net.freemacsoft.AppCleaner",
                identifier: "2.net.freemacsoft.AppCleaner",
                container: nil,
                url: URL(string: "file:///Applications/AppCleaner.app/"),
                type: 0x2, disposition: 0x3
            )
        ])

        let records = try XCTUnwrap(BTMStore(directory: directory, currentUser: { Self.thisUser }).records())

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].name, "AppCleaner")
        XCTAssertEqual(records[0].developerName, "Julien Ramseier")
        XCTAssertEqual(records[0].bundleIdentifier, "net.freemacsoft.AppCleaner")
        XCTAssertEqual(records[0].identifier, "2.net.freemacsoft.AppCleaner")
        XCTAssertEqual(records[0].rawURLPath, "/Applications/AppCleaner.app")
        XCTAssertEqual(records[0].type, "app")
        XCTAssertEqual(records[0].disposition, "on, allowed")
    }

    func testAnEmbeddedItemKeepsItsPathRelative() throws {
        // The archive holds an embedded helper as a relative URL against a
        // `file:///` base. Asking that for `path` hands back
        // `/Contents/Library/…`, a file at the root of the disk that has
        // never existed, and the helper reads as a leftover.
        let directory = try makeStore(items: [
            FixtureItem(
                name: "AppCleaner SmartDelete", developerName: nil,
                bundleIdentifier: "net.freemacsoft.AppCleaner-SmartDelete",
                identifier: "4.net.freemacsoft.AppCleaner-SmartDelete",
                container: "2.net.freemacsoft.AppCleaner",
                url: URL(string: "Contents/Library/LoginItems/AppCleaner%20SmartDelete.app",
                         relativeTo: URL(string: "file:///")),
                type: 0x4, disposition: 0x9
            )
        ])

        let records = try XCTUnwrap(BTMStore(directory: directory, currentUser: { Self.thisUser }).records())

        XCTAssertEqual(records[0].rawURLPath, "Contents/Library/LoginItems/AppCleaner SmartDelete.app")
        XCTAssertTrue(records[0].hasRelativeURL)
        XCTAssertEqual(records[0].parentIdentifier, "2.net.freemacsoft.AppCleaner")
    }

    func testAnUnreadableStoreIsNotAnEmptyOne() {
        // "Did not look" and "nothing found" are different claims, and only
        // the first one is true when Full Disk Access is off.
        let nowhere = URL(fileURLWithPath: "/var/db/there-is-no-such-directory")
        XCTAssertNil(BTMStore(directory: nowhere, currentUser: { Self.thisUser }).records())
    }

    func testThisAccountHasADirectoryUUID() {
        // The store files are named after it, so without this nothing is
        // read at all. It is also the one part that cannot be faked in a
        // fixture, since it comes from the directory service.
        XCTAssertNotNil(BTMStore.directoryUUID(for: getuid()))
    }

    // MARK: - Bit fields

    func testTypesAndDispositionsReadAsWords() {
        XCTAssertEqual(BTMDisposition.typeDescription(0x2), "app")
        XCTAssertEqual(BTMDisposition.typeDescription(0x4), "login item")
        XCTAssertEqual(BTMDisposition.typeDescription(0x2000), "background task")
        XCTAssertEqual(BTMDisposition.describe(0x0), "off")
        XCTAssertEqual(BTMDisposition.describe(0xb), "on, allowed, notified")
        XCTAssertTrue(BTMDisposition.isEnabled(0x9))
        XCTAssertFalse(BTMDisposition.isEnabled(0x2))
    }

    func testAnUnknownBitIsShownAsItsNumberRatherThanGuessedAt() {
        // A wrong label here is read as a fact about the user's Mac.
        XCTAssertEqual(BTMDisposition.typeDescription(0x400000), "type 0x400000")
        XCTAssertEqual(BTMDisposition.typeDescription(0x400002), "app (0x400002)")
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

/// Writes the same archive macOS writes, so the reader is tested against the
/// shape it will meet rather than against itself.
@objc(BrimFixtureStore)
private final class FixtureStore: NSObject, NSCoding {
    let items: [FixtureItem]
    init(items: [FixtureItem]) { self.items = items }
    init?(coder: NSCoder) { items = [] }
    func encode(with coder: NSCoder) { coder.encode(items, forKey: "records") }
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

    init?(coder: NSCoder) { return nil }

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
