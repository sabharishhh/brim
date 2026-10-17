import XCTest
@testable import BrimCore

/// Naming a background service without naming it too well. `contactsd` is
/// not the Contacts app: it serves every app that reads contacts and runs
/// whether or not Contacts was ever opened. A misleading name is worse than
/// an opaque one, because it gets acted on.
final class RunningProcessIdentityTests: XCTestCase {

    private func identity(_ path: String, bundle: String? = nil) -> RunningProcessIdentity {
        RunningProcessIdentity.of(bundlePath: bundle, executablePath: path)
    }

    // MARK: - The naming trap

    /// A daemon's name describes the service, never an application someone could
    /// look for.
    func testNoSystemServiceIsNamedAfterAnApplication() {
        // Apps that ship with macOS and that a person would recognise.
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

    /// Whole-word matching, so a third-party binary that starts the same way is
    /// not claimed as Apple's.
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

    /// Apple's apps live under `/System/Applications`. Music playing an album is
    /// the person's to quit, not a service that finishes on its own.
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
        // A daemon with no written description is still known to be macOS's from
        // its path.
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
        // The outermost bundle, not the nested one.
        XCTAssertEqual(helper.explanation, "Part of Claude.")
    }

    func testAPackageManagerBinaryIsACommandLineTool() {
        XCTAssertEqual(identity("/opt/homebrew/bin/ripgrep").kind, .commandLineTool)
        XCTAssertEqual(identity("/usr/local/bin/docker").kind, .commandLineTool)
    }

    /// A row Brim cannot place says nothing rather than guessing.
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

    /// Every daemon the table covers, so the rules are checked against all of
    /// them.
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
