import BrimCore
import XCTest

/// Grouping the background list by application. Each case was a row someone
/// took for a duplicate: separate records listed by mechanism instead of
/// by owner.
final class RegistrationGroupTests: XCTestCase {
    private func item(
        _ kind: Registration.Kind, _ label: String,
        owner: String? = nil, program: String? = nil, record: String? = nil,
        exists: Bool = true, system: Bool = false
    ) -> Registration {
        Registration(
            kind: kind, identifier: label, label: label, owningBundleID: owner,
            programPath: program, targetExists: exists, recordPath: record,
            evidence: "because", isSystemOwned: system
        )
    }

    /// An app extension points at the `.appex` inside an app, so it is named for
    /// that app, not its own label ("NotificationService").
    func testAnExtensionIsNamedAfterTheApplicationItLivesIn() {
        let groups = RegistrationGroup.group([
            item(.appExtension, "NotificationService", owner: "com.amazon.aiv.AIVApp.NotificationService",
                 program: "/Applications/Prime Video.app/Contents/PlugIns/NotificationService.appex")
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].displayName, "Prime Video")
    }

    func testTheApplicationsOwnNameStillWinsOverThePath() {
        // Where a record points at the bundle, its label is the better name.
        let groups = RegistrationGroup.group([
            item(.backgroundItem, "Visual Studio Code", owner: "com.microsoft.VSCode",
                 program: "/Applications/Code.app"),
            item(.appExtension, "Helper", owner: "com.microsoft.VSCode",
                 program: "/Applications/Code.app/Contents/PlugIns/Helper.appex")
        ])

        XCTAssertEqual(groups[0].displayName, "Visual Studio Code")
    }

    func testARecordWithNoPathAtAllKeepsItsLabel() {
        let groups = RegistrationGroup.group([
            item(.backgroundItem, "com.example.agent", owner: "com.example.agent")
        ])
        XCTAssertEqual(groups[0].displayName, "com.example.agent")
    }

    func testAnAppAndItsBackgroundTasksAreOneEntry() {
        // An app and its background tasks are one group.
        let groups = RegistrationGroup.group([
            item(.backgroundItem, "Visual Studio Code", owner: "com.microsoft.VSCode",
                 program: "/Applications/Visual Studio Code.app"),
            item(.backgroundItem, "Visual Studio Code - background tasks",
                 owner: "com.microsoft.VSCode")
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].displayName, "Visual Studio Code")
        XCTAssertEqual(groups[0].items.count, 2)
    }

    func testAHelperWithItsOwnIdentityStillSitsUnderItsApp() {
        // A dock tile plugin with its own bundle id still belongs to its app.
        let groups = RegistrationGroup.group([
            item(.backgroundItem, "ChatGPT", owner: "com.openai.codex",
                 program: "/Applications/ChatGPT.app"),
            item(.backgroundItem, "CodexDockTilePlugin.docktileplugin", owner: "com.openai.codex",
                 program: "/Applications/ChatGPT.app/Contents/PlugIns/CodexDockTilePlugin.docktileplugin")
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].displayName, "ChatGPT")
    }

    func testTheSameJobInTwoDomainsStaysTwoRowsUnderOneOwner() {
        // The same job installed for the account and the machine: two real files,
        // one piece of software.
        let groups = RegistrationGroup.group([
            item(.launchdJob, "com.google.keystone.agent", owner: "com.google.keystone.agent",
                 record: "/Users/someone/Library/LaunchAgents/com.google.keystone.agent.plist"),
            item(.launchdJob, "com.google.keystone.agent", owner: "com.google.keystone.agent",
                 record: "/Library/LaunchAgents/com.google.keystone.agent.plist")
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].items.count, 2)
        XCTAssertEqual(Set(groups[0].items.map(\.id)).count, 2,
                       "Two files are two entries. Sharing an id collapsed them into one row.")
    }

    func testTwoJobsFromOneVendorAreNotMergedOnTheirNames() {
        // Two jobs sharing only a prefix stay apart; merging would be a guess.
        let groups = RegistrationGroup.group([
            item(.launchdJob, "com.google.keystone.agent", owner: "com.google.keystone.agent"),
            item(.launchdJob, "com.google.keystone.xpcservice", owner: "com.google.keystone.xpcservice")
        ])

        XCTAssertEqual(groups.count, 2)
    }

    func testAnUnclaimedEntryKeepsItsOwnRow() {
        let groups = RegistrationGroup.group([item(.launchdJob, "orphan.job")])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].displayName, "orphan.job")
    }

    func testMissingBackgroundTargetsDoNotPromiseAutomaticCollection() {
        // Background items macOS drops by itself shortly after are reported as
        // clearing themselves.
        let sweeps = RegistrationGroup.group([
            item(.backgroundItem, "AppCleaner", owner: "net.freemacsoft.AppCleaner",
                 program: "/Applications/AppCleaner.app", exists: false)
        ])
        XCTAssertFalse(sweeps[0].staleClearsItself)

        let persists = RegistrationGroup.group([
            item(.launchdJob, "com.vendor.agent", owner: "com.vendor.agent",
                 program: "/Applications/Gone.app/Contents/MacOS/agent", exists: false)
        ])
        XCTAssertFalse(persists[0].staleClearsItself,
                       "A launchd plist is a file. Nothing collects it.")
    }

    func testCompositionCountsWhatIsUnderneath() {
        let groups = RegistrationGroup.group([
            item(.launchdJob, "a", owner: "vendor"),
            item(.launchdJob, "b", owner: "vendor"),
            item(.backgroundItem, "c", owner: "vendor")
        ])
        XCTAssertEqual(groups[0].composition, "2 background jobs, background item")
    }
}

/// A launchd job file named for removal is unloaded first, or it is gone
/// from disk and still running.
final class LaunchdJobFileTests: XCTestCase {
    func testJobFilesAreRecognisedByWhereTheyLive() {
        let agents = "/Users/someone/Library/LaunchAgents/com.google.keystone.agent.plist"
        let daemons = "/Library/LaunchDaemons/com.vendor.helper.plist"
        XCTAssertTrue(LaunchdJobFile.isOne(URL(fileURLWithPath: agents)))
        XCTAssertTrue(LaunchdJobFile.isOne(URL(fileURLWithPath: daemons)))
    }

    func testAPlistSomewhereElseIsJustAFile() {
        // launchd loads only its own folders, so a preferences plist is not a job
        // however it is named.
        let preference = "/Users/someone/Library/Preferences/com.google.keystone.agent.plist"
        XCTAssertFalse(LaunchdJobFile.isOne(URL(fileURLWithPath: preference)))
        XCTAssertFalse(LaunchdJobFile.isOne(URL(fileURLWithPath: "/Library/LaunchAgents/readme.txt")))
    }
}
