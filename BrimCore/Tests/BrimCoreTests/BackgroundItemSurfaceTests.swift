import BrimCore
@testable import BrimScan
import XCTest

/// Turning Background Task Management records into registrations, against
/// fixtures from a real Mac. Each case here was once a false "stale"
/// reading, which would offer to remove a working app's registration.
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
        BackgroundItemSurface(
            read: { BTMParser().parse(dump: text) },
            homeDirectory: { homes[$0] }
        )
    }

    func testAnItemWithNoURLIsNotReportedStale() async {
        // "(null)" is what is recorded for a background-tasks record, not a path.
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
        // An embedded item's path is relative to the app that ships it.
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
        // The home folder is recorded as `/Users/<uid>`, which does not exist.
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

        // No home for uid 999: the path is left as recorded rather than guessed for
        // the wrong account.
        let found = await surface(text, homes: [:]).registrations(in: root)
        let item = try XCTUnwrap(found.first { $0.label == "OtherUserAgent" })
        XCTAssertNil(item.programPath)
        XCTAssertEqual(item.rawTargetPath, "/Users/999/Library/Thing.app")
        XCTAssertTrue(item.targetPresence.isUnknown)
        XCTAssertFalse(item.isStale)
    }

    func testAHelperIsAttributedToTheAppThatShipsIt() async throws {
        // Uninstalling the parent app must clear its login item, so the child
        // carries the parent's bundle identifier.
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
        XCTAssertFalse(ghost.isActionableStale, "A listed BTM record has no scoped removal API")
        XCTAssertTrue(ghost.evidence.contains("missing"))
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

    /// An Apple item with no bundle identifier or URL, only
    /// `4096.com.apple.stocks`, is still Apple's.
    func testAnAppleItemWithNothingButItsIdentifierIsStillApples() async {
        let text = dump("""

         #1:
                         UUID: FFFF
                         Name: Stocks - background app refresh
                   Identifier: 4096.com.apple.stocks
                          URL: (null)
            Parent Identifier: 2.com.apple.stocks
        """)

        let found = await surface(text).registrations(in: root)
        let stocks = try? XCTUnwrap(found.first { $0.label == "Stocks - background app refresh" })
        XCTAssertEqual(stocks?.isSystemOwned, true,
                       "Only the identifiers name the owner, and both of them say Apple")
    }

    /// The other half: the same shape from another developer stays in the list.
    func testTheSameShapeFromSomebodyElseStaysInTheList() async {
        let text = dump("""

         #1:
                         UUID: FFFF
                         Name: Visual Studio Code - background tasks
                   Identifier: 8192.com.microsoft.VSCode
                          URL: (null)
            Parent Identifier: 2.com.microsoft.VSCode
        """)

        let found = await surface(text).registrations(in: root)
        XCTAssertEqual(found.first?.isSystemOwned, false)
    }

    /// The type prefix is digits and a dot, and nothing else may be stripped.
    func testOnlyTheRecordTypeIsTakenOffAnIdentifier() {
        XCTAssertEqual(
            BackgroundItemSurface.bundleIdentifier(in: "4096.com.apple.stocks"),
            "com.apple.stocks"
        )
        XCTAssertEqual(
            BackgroundItemSurface.bundleIdentifier(in: "com.apple.stocks"),
            "com.apple.stocks",
            "An identifier with no type prefix comes back whole"
        )
        XCTAssertEqual(
            BackgroundItemSurface.bundleIdentifier(in: "2x.com.example.app"),
            "2x.com.example.app",
            "A first component that merely starts with a digit is not a type"
        )
        XCTAssertEqual(
            BackgroundItemSurface.bundleIdentifier(in: "2."), "",
            "A type and nothing after it names no bundle, and says so rather than "
                + "offering the type as if it were one"
        )
        XCTAssertEqual(BackgroundItemSurface.bundleIdentifier(in: ""), "")
        XCTAssertEqual(
            BackgroundItemSurface.bundleIdentifier(in: ".com.apple.x"), ".com.apple.x",
            "An empty first component is not a type either"
        )
    }

    func testAnUnreadableStoreReportsNoCoverageRatherThanNoItems() async {
        let blind = BackgroundItemSurface(read: { nil }, homeDirectory: { _ in nil })

        let coverage = await blind.coverage(in: root)
        XCTAssertFalse(coverage.available)
        XCTAssertNotNil(coverage.limitation, "A surface that could not be read must say so")
        let items = await blind.registrations(in: root)
        XCTAssertTrue(items.isEmpty)
    }
}

/// Nothing on the scan path may ask for anything. Running `sfltool dumpbtm`
/// raised an administrator prompt; the store is read directly instead.
final class BackgroundItemPromptTests: XCTestCase {
    func testTheScanPathDoesNotRunSFLTool() throws {
        let scan = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BrimCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BrimCore
            .appendingPathComponent("Sources/BrimScan")

        let files = FileManager.default.enumerator(at: scan, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "Could not find the scan sources at \(scan.path)")

        // The executable path, not the word: these files mention the tool to
        // explain why it is not used.
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for invocation in ["/usr/bin/sfltool", "\"sfltool"] {
                XCTAssertFalse(
                    text.contains(invocation),
                    "\(file.lastPathComponent) reaches for sfltool, which asks the user for an "
                        + "administrator password in the middle of a scan"
                )
            }
        }
    }

    func testReadingHappensOncePerReport() async {
        // Each surface is read once, though both registrations and coverage are
        // asked for.
        let runs = RunCounter()
        let surface = BackgroundItemSurface(read: { runs.record(); return [] })
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))

        _ = await surface.registrations(in: root)
        _ = await surface.coverage(in: root)

        XCTAssertLessThanOrEqual(runs.count, 2)
    }

    private final class RunCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() {
            lock.lock(); value += 1; lock.unlock()
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }
}

/// An emptied launchd job file, as some uninstallers leave, is a leftover,
/// not a healthy registration.
final class EmptyLaunchdJobTests: XCTestCase {
    func testAJobWithNothingToRunIsNotRunning() {
        let job = LaunchdRegistrationSurface.parse(dictionary: [:], fallbackLabel: "com.google.keystone.agent")

        XCTAssertNil(job, "An empty dictionary has no required Label and cannot identify a launchd service.")
        XCTAssertNil(job?.program, "An empty plist names no program")
    }

    func testAJobWithAProgramIsReadNormally() {
        let job = LaunchdRegistrationSurface.parse(
            dictionary: ["Label": "com.vendor.agent", "ProgramArguments": ["/usr/local/bin/agent", "-x"]],
            fallbackLabel: "ignored"
        )

        XCTAssertEqual(job?.label, "com.vendor.agent")
        XCTAssertEqual(job?.program, "/usr/local/bin/agent")
    }
}
