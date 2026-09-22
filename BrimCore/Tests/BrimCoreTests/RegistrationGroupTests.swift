import XCTest
import BrimCore

/// Grouping the background list by application.
///
/// Each case here is a row a user pointed at and said it looked like a
/// duplicate. None of them were duplicates. They were separate records
/// listed by mechanism instead of by owner, which is the same failure the
/// leftovers list had.
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

    /// Every app extension on this Mac headed its own group with its own
    /// label: "NotificationService" for Prime Video's, "OpenInIINA" for
    /// IINA's, "Intents" and "ServiceExtension" for WhatsApp's. None of those
    /// records points at a `.app`, because each points at the `.appex` inside
    /// one, so the app-bundle check missed them and the shortest-label
    /// tiebreak named the group after the plug-in. A person scanning that
    /// list cannot tell what any of them is.
    func testAnExtensionIsNamedAfterTheApplicationItLivesIn() {
        let groups = RegistrationGroup.group([
            item(.appExtension, "NotificationService", owner: "com.amazon.aiv.AIVApp.NotificationService",
                 program: "/Applications/Prime Video.app/Contents/PlugIns/NotificationService.appex")
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].displayName, "Prime Video")
    }

    func testTheApplicationsOwnNameStillWinsOverThePath() {
        // Where a record does point at the bundle, its label is the better
        // name: it is what the developer called the product, not what the
        // folder is called.
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
        // Visual Studio Code was listed twice, once as itself and once as
        // "Visual Studio Code - background tasks", with nothing on screen
        // connecting them.
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
        // ChatGPT's dock tile plugin has a bundle id of its own. Attributing
        // it to itself split one application in two.
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
        // Keystone installs each job twice, once for the account and once
        // for the machine. They are two real files and must both be shown,
        // but they belong to one piece of software.
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
        // com.google.keystone.agent and com.google.keystone.xpcservice share
        // a prefix and nothing else. Merging on that would be a guess, and
        // the rule everywhere else in Brim is evidence over resemblance.
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

    func testWhatMacOSClearsIsKeptApartFromWhatItDoesNot() {
        // The AppCleaner incident: two background items reported as left
        // behind, which macOS dropped by itself a couple of minutes later.
        let sweeps = RegistrationGroup.group([
            item(.backgroundItem, "AppCleaner", owner: "net.freemacsoft.AppCleaner",
                 program: "/Applications/AppCleaner.app", exists: false)
        ])
        XCTAssertTrue(sweeps[0].staleClearsItself)

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

/// A launchd job file named for removal has to be unloaded first.
///
/// The Background section names plist paths directly, with no application
/// to discover them from. Planned as ordinary files they would be trashed
/// while still loaded: gone from disk, still running, and nothing left to
/// explain why.
final class LaunchdJobFileTests: XCTestCase {

    func testJobFilesAreRecognisedByWhereTheyLive() {
        let agents = "/Users/someone/Library/LaunchAgents/com.google.keystone.agent.plist"
        let daemons = "/Library/LaunchDaemons/com.vendor.helper.plist"
        XCTAssertTrue(LaunchdJobFile.isOne(URL(fileURLWithPath: agents)))
        XCTAssertTrue(LaunchdJobFile.isOne(URL(fileURLWithPath: daemons)))
    }

    func testAPlistSomewhereElseIsJustAFile() {
        // launchd loads what is in its directories and ignores the rest,
        // so a preferences plist is not a job however it is named.
        let preference = "/Users/someone/Library/Preferences/com.google.keystone.agent.plist"
        XCTAssertFalse(LaunchdJobFile.isOne(URL(fileURLWithPath: preference)))
        XCTAssertFalse(LaunchdJobFile.isOne(URL(fileURLWithPath: "/Library/LaunchAgents/readme.txt")))
    }
}
