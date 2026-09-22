import XCTest
@testable import BrimCore

/// Naming a background service, and the trap of naming it too well.
///
/// The energy panel used to print executable names: `contactsd`, `suggestd`,
/// `duetexpertd`, `mediaanalysisd`, `spotlightknowledged.updater`. Those were
/// the five largest consumers on a real Mac and not one of them told anybody
/// anything.
///
/// The first fix made it worse. `contactsd` became "Contacts", and the person
/// reading it had opened the Contacts app once, ever, to see what a native Mac
/// app looked like. The panel appeared to say that an app they never use had
/// cost 4.2% of a charge. It had not: `contactsd` holds the contacts database
/// and answers every app that reads from it, plus iCloud sync, and runs
/// whether or not the Contacts app has ever been opened.
///
/// Replacing an opaque name with a misleading one is worse than leaving it
/// opaque, because the second one gets acted on.
final class RunningProcessIdentityTests: XCTestCase {

    private func identity(_ path: String, bundle: String? = nil) -> RunningProcessIdentity {
        RunningProcessIdentity.of(bundlePath: bundle, executablePath: path)
    }

    // MARK: - The naming trap

    /// Every name Brim gives an Apple daemon must be a description of the
    /// service, never the name of an application somebody could go and look
    /// for in their Applications folder.
    func testNoSystemServiceIsNamedAfterAnApplication() {
        // Apps that ship with macOS and whose names a person would recognise
        // as something they can open, quit, or blame.
        let applicationNames = [
            "Contacts", "Photos", "Mail", "Messages", "Calendar", "Notes",
            "Safari", "Music", "Reminders", "Maps", "News", "Finder",
            "Siri", "Spotlight", "Shortcuts", "Books", "Podcasts"
        ]

        for daemon in Self.knownDaemons {
            guard let service = RunningProcessIdentity.appleService(named: daemon) else {
                continue
            }
            XCTAssertFalse(
                applicationNames.contains(service.name),
                "\(daemon) is called \"\(service.name)\", which is the name of an app. "
                + "A person reading that concludes an app they may never open is costing them "
                + "battery, when the daemon runs for the whole system."
            )
        }
    }

    func testTheContactsDaemonSaysItRunsForOtherSoftware() {
        let service = RunningProcessIdentity.appleService(named: "contactsd")
        let explanation = try? XCTUnwrap(service?.explanation)

        XCTAssertEqual(service?.name, "Contacts database")
        XCTAssertTrue(
            (explanation ?? "").contains("whether or not you use the Contacts app"),
            "The one thing worth saying about this row is the thing that was missing: "
            + "it does not mean you used the app."
        )
    }

    func testEveryServiceExplainsItselfInASentence() {
        for daemon in Self.knownDaemons {
            guard let service = RunningProcessIdentity.appleService(named: daemon) else { continue }
            XCTAssertFalse(service.name.isEmpty, "\(daemon) has no name")
            XCTAssertFalse(service.explanation.isEmpty, "\(daemon) explains nothing")
            XCTAssertTrue(
                service.explanation.hasSuffix(".") || service.explanation.hasSuffix("?"),
                "\(daemon)'s explanation is not a sentence: \(service.explanation)"
            )
        }
    }

    /// Whole-word matching, so a third-party binary that merely starts the
    /// same way is not claimed as Apple's.
    func testANameThatMerelyStartsTheSameIsNotClaimed() {
        XCTAssertNil(RunningProcessIdentity.appleService(named: "contactsdaemon"))
        XCTAssertNil(RunningProcessIdentity.appleService(named: "mdsomething"))
        XCTAssertNil(RunningProcessIdentity.appleService(named: "suggestdx"))
    }

    // MARK: - Classification, which is derived rather than guessed

    func testAnApplicationBundleIsAnApplication() {
        let claude = identity(
            "/Applications/Claude.app/Contents/MacOS/Claude",
            bundle: "/Applications/Claude.app"
        )
        XCTAssertEqual(claude.kind, .application)
        XCTAssertEqual(claude.displayName, "Claude")
        XCTAssertTrue(claude.kind.isActionable, "Quitting it is a thing a person can do")
    }

    /// Every app Apple ships now lives under `/System/Applications`: Music,
    /// Safari, Mail, Notes, Photos. Filing anything under `/System/` as a
    /// service put all of them in the half of the panel headed "most of this
    /// finishes on its own" and badged them as nobody's to stop. Music
    /// playing an album is a person's to quit.
    func testAnAppleApplicationIsAnApplicationAndNotAService() {
        for app in ["Music", "Safari", "Mail", "Notes", "Photos"] {
            let identity = RunningProcessIdentity.of(
                bundlePath: "/System/Applications/\(app).app",
                executablePath: "/System/Applications/\(app).app/Contents/MacOS/\(app)"
            )
            XCTAssertEqual(identity.kind, .application, "\(app) is an app a person opens")
            XCTAssertTrue(identity.kind.isActionable, "\(app) can be quit")
            XCTAssertEqual(identity.displayName, app)
        }
    }

    func testSomethingUnderSystemLibraryIsStillAService() {
        let identity = RunningProcessIdentity.of(
            bundlePath: "/System/Library/CoreServices/Dock.app",
            executablePath: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
        )
        XCTAssertEqual(identity.kind, .systemService)
    }

    func testSomethingUnderSystemBelongsToMacOSEvenWhenUnrecognised() {
        // The point of deriving from the path: a daemon nobody has written a
        // sentence for is still known to be macOS's, which is the fact that
        // decides which half of the panel it goes in.
        let unknown = identity("/System/Library/PrivateFrameworks/Whatever.framework/somethingd")
        XCTAssertEqual(unknown.kind, .systemService)
        XCTAssertFalse(unknown.kind.isActionable)
        XCTAssertEqual(unknown.displayName, "somethingd", "No name is invented for it")
    }

    func testAHelperIsNamedAfterTheApplicationItLivesIn() {
        let helper = identity(
            "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
        )
        XCTAssertEqual(helper.kind, .helper)
        // The outermost bundle, not the nested one: a person knows Claude,
        // and "Part of Claude Helper" would just be the row's own name back.
        XCTAssertEqual(helper.explanation, "Part of Claude.")
    }

    func testAPackageManagerBinaryIsACommandLineTool() {
        XCTAssertEqual(identity("/opt/homebrew/bin/ripgrep").kind, .commandLineTool)
        XCTAssertEqual(identity("/usr/local/bin/docker").kind, .commandLineTool)
    }

    /// A row Brim cannot place says so by saying nothing, rather than being
    /// filed under a guess.
    func testSomethingElsewhereIsNotGuessedAt() {
        let other = identity("/Users/someone/scratch/a.out")
        XCTAssertEqual(other.kind, .other)
        XCTAssertNil(other.explanation)
    }

    func testProcessesOfOneApplicationShareAGroupKey() {
        let app = identity("/Applications/Claude.app/Contents/MacOS/Claude",
                           bundle: "/Applications/Claude.app")
        let renderer = identity("/Applications/Claude.app/Contents/Frameworks/R.app/Contents/MacOS/R",
                                bundle: "/Applications/Claude.app")
        XCTAssertEqual(app.groupKey, renderer.groupKey)
    }

    /// Every daemon the table is meant to cover, so the rules above are
    /// checked against all of them rather than against a sample.
    private static let knownDaemons = [
        "contactsd", "suggestd", "duetexpertd", "mediaanalysisd", "photoanalysisd",
        "spotlightknowledged", "spotlightknowledged.updater", "mds", "mds_stores",
        "mdworker", "mdworker_shared", "WindowServer", "WindowManager", "kernel_task",
        "backupd", "cloudd", "bird", "syncdefaultsd", "appleaccountd", "akd",
        "knowledge-agent", "corespotlightd", "powerd", "coreaudiod", "bluetoothd",
        "sharingd", "trustd", "nsurlsessiond", "assistantd", "siriactionsd",
        "generativeexperiencesd", "sysmond", "distnoted", "notifyd"
    ]
}
