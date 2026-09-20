import XCTest
import BrimCore
@testable import BrimScan

/// Parsing `sfltool dumpbtm`, against fixtures taken verbatim from a real
/// machine's output.
///
/// Every case here was a false "stale" reading before it was fixed. A sweep
/// that invents leftovers is worse than one that finds none, because the
/// action it offers is removing a registration from a working app.
final class BackgroundItemSurfaceTests: XCTestCase {

    private let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))

    /// Shape copied from real `sfltool dumpbtm` output.
    private func dump(_ items: String) -> String {
        """
        ========================
         Records for UID 501 : C995F5A3-ED44-45EF-B512-E97AEBAFDE8A
        ========================

         ServiceManagement migrated: true
         LaunchServices registered: true

         Items:
        \(items)
        """
    }

    private func surface(_ text: String, homes: [uid_t: String] = [501: "/Users/tester"]) -> BackgroundItemSurface {
        BackgroundItemSurface(dump: { text }, homeDirectory: { homes[$0] })
    }

    func testAnItemWithNoURLIsNotReportedStale() async {
        // "(null)" is what sfltool prints for a background-tasks record.
        // Treated as a path it becomes a file that never existed.
        let text = dump("""

         #1:
                         UUID: E2BB73BD-0931-4F92-AD99-1BC00F6D5AFE
                         Name: Antigravity - background tasks
                         Type: background tasks (0x2000)
                   Identifier: 8192.com.google.antigravity
                          URL: (null)
            Parent Identifier: 2.com.google.antigravity
        """)

        let found = await surface(text).registrations(in: root)
        let item = found.first { $0.label.contains("background tasks") }

        XCTAssertNotNil(item)
        XCTAssertNil(item?.programPath, "(null) is not a path")
        XCTAssertFalse(item?.isStale ?? true, "No URL says nothing about whether the owner is present")
    }

    func testAnEmbeddedItemResolvesAgainstItsParentNotTheWorkingDirectory() async throws {
        // sfltool prints an embedded item's path relative to the app that
        // ships it. Resolved as absolute it lands under the CWD and vanishes.
        let text = dump("""

         #1:
                         UUID: AAAA
                         Name: AppCleaner
                         Type: app (0x2)
                   Identifier: 2.net.freemacsoft.AppCleaner
                          URL: /Applications/AppCleaner.app
            Bundle Identifier: net.freemacsoft.AppCleaner

         #2:
                         UUID: BBBB
                         Name: AppCleaner SmartDelete
                         Type: login item (0x4)
                   Identifier: 4.net.freemacsoft.AppCleaner-SmartDelete
                          URL: Contents/Library/LoginItems/AppCleaner SmartDelete.app
            Bundle Identifier: net.freemacsoft.AppCleaner-SmartDelete
            Parent Identifier: 2.net.freemacsoft.AppCleaner
        """)

        let found = await surface(text).registrations(in: root)
        let child = try XCTUnwrap(found.first { $0.label == "AppCleaner SmartDelete" })

        XCTAssertEqual(
            child.programPath,
            "/Applications/AppCleaner.app/Contents/Library/LoginItems/AppCleaner SmartDelete.app",
            "An embedded item must resolve against its parent bundle"
        )
    }

    func testAHomeDirectoryPrintedAsAUIDIsResolvedToTheRealHome() async throws {
        // Observed with Figma: sfltool renders the home directory as
        // /Users/<uid>, a path that does not exist, so a healthy login item
        // reads as a leftover.
        let text = dump("""

         #1:
                         UUID: CCCC
                         Name: FigmaAgent
                         Type: app (0x2)
                   Identifier: 2.com.figma.agent
                          URL: /Users/501/Library/Application Support/Figma/FigmaAgent.app
            Bundle Identifier: com.figma.agent
        """)

        let found = await surface(text).registrations(in: root)
        let agent = try XCTUnwrap(found.first { $0.label == "FigmaAgent" })

        XCTAssertEqual(
            agent.programPath,
            "/Users/tester/Library/Application Support/Figma/FigmaAgent.app",
            "The UID placeholder must resolve to that account's home directory"
        )
    }

    func testAnUnknownUIDIsLeftAloneRatherThanGuessed() async throws {
        let text = dump("""

         #1:
                         UUID: DDDD
                         Name: OtherUserAgent
                   Identifier: 2.com.other.agent
                          URL: /Users/999/Library/Thing.app
            Bundle Identifier: com.other.agent
        """)

        // No home for uid 999: leave the path as printed rather than
        // inventing one for the wrong account.
        let found = await surface(text, homes: [:]).registrations(in: root)
        let item = try XCTUnwrap(found.first { $0.label == "OtherUserAgent" })
        XCTAssertEqual(item.programPath, "/Users/999/Library/Thing.app")
    }

    func testAHelperIsAttributedToTheAppThatShipsIt() async throws {
        // Uninstalling the parent app must clear its login item, so the
        // child has to carry the parent's bundle identifier.
        let text = dump("""

         #1:
                         UUID: AAAA
                         Name: Parent
                   Identifier: 2.com.vendor.parent
                          URL: /Applications/Parent.app
            Bundle Identifier: com.vendor.parent

         #2:
                         UUID: BBBB
                         Name: Parent background tasks
                   Identifier: 8192.com.vendor.parent
                          URL: (null)
            Parent Identifier: 2.com.vendor.parent
        """)

        let found = await surface(text).registrations(in: root)
        let child = try XCTUnwrap(found.first { $0.label == "Parent background tasks" })

        XCTAssertEqual(child.owningBundleID, "com.vendor.parent")
        XCTAssertTrue(
            child.belongs(to: Identity(bundleID: "com.vendor.parent", name: "Parent"), bundleURL: nil),
            "The parent app owns its background-tasks record"
        )
    }

    func testAGenuinelyMissingApplicationIsReportedStale() async throws {
        let text = dump("""

         #1:
                         UUID: EEEE
                         Name: Ghost
                   Identifier: 2.com.vendor.ghost
                          URL: /Applications/DefinitelyNotInstalled-\(UUID().uuidString).app
            Bundle Identifier: com.vendor.ghost
        """)

        let found = await surface(text).registrations(in: root)
        let ghost = try XCTUnwrap(found.first { $0.label == "Ghost" })

        XCTAssertTrue(ghost.isStale)
        XCTAssertTrue(ghost.isActionableStale, "A third-party leftover is actionable")
        XCTAssertTrue(ghost.evidence.contains("gone"))
    }

    func testAppleItemsAreNeverOfferedAsCleanable() async throws {
        let text = dump("""

         #1:
                         UUID: FFFF
                         Name: WeatherMenu
                   Identifier: 2.com.apple.weather.menu
                          URL: /Applications/NotThere-\(UUID().uuidString).app
            Bundle Identifier: com.apple.weather.menu
        """)

        let found = await surface(text).registrations(in: root)
        let apple = try XCTUnwrap(found.first { $0.label == "WeatherMenu" })

        XCTAssertTrue(apple.isSystemOwned)
        XCTAssertFalse(apple.isActionableStale)
    }

    func testAnUnreadableDumpReportsNoCoverageRatherThanNoItems() async {
        let blind = BackgroundItemSurface(dump: { nil }, homeDirectory: { _ in nil })

        let coverage = await blind.coverage(in: root)
        XCTAssertFalse(coverage.available)
        XCTAssertNotNil(coverage.limitation, "A surface that could not be read must say so")
        let items = await blind.registrations(in: root)
        XCTAssertTrue(items.isEmpty)
    }
}
