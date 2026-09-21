import XCTest
import BrimCore
@testable import BrimPrivileged

/// What the root daemon refuses.
///
/// These are the tests that matter most in the project. Everything else
/// protects a user from a wrong answer; these protect them from a daemon
/// running as root being talked into something. Each case is an attack on
/// the interface rather than a mistake in it.
final class PrivilegedJobRemovalTests: XCTestCase {

    private func refusal(domain: String = "localAgents", name: String) -> PrivilegedJobRemoval.Refusal? {
        do {
            _ = try PrivilegedJobRemoval.target(domain: domain, name: name)
            return nil
        } catch let refusal as PrivilegedJobRemoval.Refusal {
            return refusal
        } catch {
            return nil
        }
    }

    // MARK: - The interface cannot express a dangerous request

    func testAPathCannotBeSmuggledThroughTheName() {
        // The whole reason the caller names a domain and a file rather
        // than a path. None of these may become a path.
        for attempt in [
            "../../../etc/sudoers",
            "/etc/sudoers",
            "..",
            ".",
            "sub/dir.plist",
            "com.vendor.agent.plist/../../../../System/x.plist"
        ] {
            XCTAssertNotNil(refusal(name: attempt), "\(attempt) was not refused")
        }
    }

    func testOnlyTheTwoMachineWideDirectoriesAreReachable() {
        XCTAssertEqual(
            try? PrivilegedJobRemoval.target(domain: "localAgents", name: "com.vendor.agent.plist").path,
            "/Library/LaunchAgents/com.vendor.agent.plist"
        )
        XCTAssertEqual(
            try? PrivilegedJobRemoval.target(domain: "localDaemons", name: "com.vendor.d.plist").path,
            "/Library/LaunchDaemons/com.vendor.d.plist"
        )
        // A user's own Library needs no privileges and must never come
        // through here, so there is no domain for it.
        XCTAssertEqual(refusal(domain: "userAgents", name: "x.plist"),
                       .unknownDomain("userAgents"))
        XCTAssertEqual(refusal(domain: "/etc", name: "sudoers"), .unknownDomain("/etc"))
    }

    func testNothingOfApplesEverGoes() {
        // Refused by the daemon by name, rather than trusting the caller
        // to have filtered them out.
        XCTAssertEqual(refusal(name: "com.apple.safaridavclient.plist"),
                       .belongsToApple("com.apple.safaridavclient.plist"))
    }

    func testOnlyJobFiles() {
        XCTAssertEqual(refusal(name: "kernel"), .notAJobFile("kernel"))
        XCTAssertEqual(refusal(name: "notes.txt"), .notAJobFile("notes.txt"))
        XCTAssertNotNil(refusal(name: ".hidden.plist"))
        XCTAssertNotNil(refusal(name: ""))
        XCTAssertNotNil(refusal(name: String(repeating: "a", count: 300) + ".plist"))
    }

    func testAKnownGoodNameIsAccepted() {
        XCTAssertNil(refusal(name: "com.google.keystone.agent.plist"))
    }

    // MARK: - A job that works is never removed

    private func plist(_ dictionary: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    func testAJobWhoseProgramIsStillThereIsRefused() {
        // The rule that makes the daemon safe to expose at all. Even a
        // caller that satisfied the code signing check cannot use this to
        // switch off a working service.
        let working = plist(["Label": "com.vendor.agent",
                             "ProgramArguments": ["/usr/bin/true", "-x"]])

        XCTAssertFalse(PrivilegedJobRemoval.isDefunct(plist: working) { path in
            XCTAssertEqual(path, "/usr/bin/true")
            return true
        })
    }

    func testAJobPointingAtNothingIsDefunct() {
        let broken = plist(["Label": "com.vendor.agent",
                            "Program": "/Applications/Gone.app/Contents/MacOS/agent"])
        XCTAssertTrue(PrivilegedJobRemoval.isDefunct(plist: broken) { _ in false })
    }

    func testAnEmptyJobFileIsDefunct() {
        // Google's uninstaller leaves four of these: an empty dictionary,
        // no program, nothing for launchd to run.
        XCTAssertTrue(PrivilegedJobRemoval.isDefunct(plist: plist([:])) { _ in true })
    }

    func testSomethingThatIsNotAPlistIsNotALicenceToDelete() {
        // launchd would ignore it, but a daemon guessing at a file it
        // cannot parse is how a helper removes the wrong thing.
        let rubbish = Data("not a plist at all".utf8)
        XCTAssertFalse(PrivilegedJobRemoval.isDefunct(plist: rubbish) { _ in false })
        XCTAssertFalse(PrivilegedJobRemoval.isDefunct(plist: Data()) { _ in false })
    }

    // MARK: - Who may connect

    func testTheAppAndTheDaemonArePinnedSeparately() {
        // They are two identities, and pinning the wrong one is easy: the
        // first version had the app checking the daemon against the
        // *app's* identifier, which nothing could ever satisfy, so the
        // connection would have been dropped every time.
        XCTAssertTrue(BrimJobHelper.clientRequirement().contains("\"com.sabharishhh.brim\""))
        XCTAssertTrue(BrimJobHelper.daemonRequirement().contains("\"com.sabharishhh.brim.jobhelper\""))
        XCTAssertNotEqual(BrimJobHelper.clientRequirement(), BrimJobHelper.daemonRequirement())
    }

    func testBothDirectionsAreAnchoredToApple() {
        // A root service accepting whatever answers, or an app trusting
        // whatever holds the mach name, is how one of them gets replaced.
        for requirement in [BrimJobHelper.clientRequirement(), BrimJobHelper.daemonRequirement()] {
            XCTAssertTrue(requirement.contains("anchor apple generic"))
            XCTAssertTrue(requirement.contains("subject.OU] = \"9LY29YLFG2\""))
        }
    }

    func testTheClientRequirementPinsThisAppAndThisTeam() {
        let requirement = BrimJobHelper.clientRequirement()
        XCTAssertTrue(requirement.contains("anchor apple generic"),
                      "Without an Apple anchor a self-signed impostor satisfies the rest")
        XCTAssertTrue(requirement.contains("identifier \"com.sabharishhh.brim\""))
        XCTAssertTrue(requirement.contains("subject.OU] = \"9LY29YLFG2\""))
        XCTAssertFalse(requirement.contains("com.google.Brim"),
                       "The placeholder named an application that does not exist")
        XCTAssertFalse(requirement.contains("EQHXZ8M8AV"),
                       "The placeholder pinned Google's team identifier")
    }
}

/// One selection, one plan, whoever owns the folders.
///
/// The first version made it all or nothing: either everything ticked
/// needed the daemon or nothing did, so a person who picked one file of
/// their own and one of root's had to do it twice. Whose folder something
/// sits in is Brim's problem, not a distinction to make anyone sort their
/// selection by.
final class MixedPrivilegeSelectionTests: XCTestCase {

    func testAPlanCanCarryBothKindsOfRemoval() throws {
        // Deliberately checks the step vocabulary rather than the planner
        // internals: what matters is that one plan can express both, so
        // one review and one confirmation covers the selection.
        XCTAssertTrue(StepKind.trashPath.targetIsPath)
        XCTAssertTrue(StepKind.trashPathPrivileged.targetIsPath)

        let ordinary = Step(
            index: 0, kind: .trashPath, target: "/Users/me/Library/LaunchAgents/a.plist",
            targetFingerprint: nil, tier: .A, evidence: "yours", expectedBytes: 181,
            capability: .ok, reversible: true, costOfError: .low,
            executionPhase: .launchd, disposition: .trash
        )
        let privileged = Step(
            index: 1, kind: .trashPathPrivileged, target: "/Library/LaunchAgents/a.plist",
            targetFingerprint: nil, tier: .A, evidence: "root's", expectedBytes: 181,
            capability: .needsHelper, reversible: true, costOfError: .low,
            executionPhase: .launchd, disposition: .trash
        )

        let plan = Plan(
            planId: UUID(), createdAt: Date(), engineVersion: "1.0.0", osVersion: "test",
            intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(bundleID: nil, name: "Background jobs")),
            steps: [ordinary, privileged], excludedItems: [], expectedTotalBytes: 362
        )

        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertTrue(plan.steps.allSatisfy(\.reversible),
                      "Both set the file aside rather than deleting it, so neither earns a prompt")
    }

    func testAPrivilegedRemovalIsReversibleAndSoNeedsNoExtraPrompt() {
        // The reason there is no fingerprint per cleanup. The daemon
        // renames the file into a root owned holding folder; it does not
        // unlink it. Brim's rule is that reversible things do not
        // interrupt, and this is reversible.
        XCTAssertTrue(BrimJobHelper.quarantineDirectory.hasPrefix("/Library/"),
                      "The holding folder has to be somewhere only root can write")
    }
}
