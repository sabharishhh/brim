import XCTest
import BrimCore
import BrimOps
import BrimPrivileged
@testable import BrimService

/// The background reset, and the list that has to exist before it runs.
///
/// A reset deregisters every login item and background service on the Mac
/// at once, and macOS keeps no record of what was there. T-3.8's whole
/// acceptance criterion is the gate: a reset cannot be initiated without a
/// captured restore list, and the list is persisted before the reset runs.
final class BTMResetGateTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("btm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeExecutor() -> (Executor, RestoreListStore, ResetSpy) {
        let lists = RestoreListStore(directoryURL: directory.appendingPathComponent("Lists"))
        let executor = Executor(
            journalStore: JournalStore(directoryURL: directory.appendingPathComponent("Journals")),
            restoreLists: lists
        )
        let spy = ResetSpy()
        return (executor, lists, spy)
    }

    /// Counts calls to `sfltool` without making any. Running the real one
    /// would deregister every background item on this machine.
    final class ResetSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var invocations: Int {
            lock.lock(); defer { lock.unlock() }; return count
        }
        func runner() -> @Sendable (String, [String]) throws -> Int32 {
            { [self] _, _ in
                lock.lock(); count += 1; lock.unlock()
                return 0
            }
        }
    }

    private func resetPlan() -> Plan {
        Plan(
            planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
            intent: PlanIntent(
                type: .reset,
                subjectIdentity: Identity(bundleID: "com.example.all", name: "Background items")
            ),
            steps: [
                Step(
                    index: 0, kind: .btmReset, target: "all", targetFingerprint: nil,
                    tier: .A, evidence: "guided reset", expectedBytes: 0,
                    capability: .ok, reversible: false, costOfError: .high
                )
            ],
            excludedItems: [], expectedTotalBytes: 0
        )
    }

    private func list(entries: Int, complete: Bool) -> BTMRestoreList {
        BTMRestoreList(
            capturedAt: Date(),
            entries: (0..<entries).map {
                BTMRestoreList.Entry(
                    name: "Item \($0)", developer: "Someone",
                    bundleIdentifier: "com.example.item\($0)",
                    path: "/Applications/Item\($0).app", type: "login item", wasEnabled: true
                )
            },
            isComplete: complete,
            gap: complete ? nil : "Full Disk Access was not granted"
        )
    }

    func testAResetWithNoListIsRefused() async throws {
        let (executor, _, spy) = makeExecutor()
        await executor.setToolRunner(spy.runner())

        let journal = try await executor.execute(plan: resetPlan())

        XCTAssertEqual(spy.invocations, 0, "sfltool ran with nothing written down")
        XCTAssertTrue(
            journal.stepOutcomes[0]?.hasPrefix("refused_no_restore_list") ?? false,
            "Got \(journal.stepOutcomes[0] ?? "nothing")"
        )
    }

    func testAnIncompleteListCountsAsNoList() async throws {
        // Without Full Disk Access the store reads short. A partial list
        // looks complete to the person holding it, and they find out what
        // was missing when something stops starting.
        let (executor, lists, spy) = makeExecutor()
        await executor.setToolRunner(spy.runner())
        let plan = resetPlan()
        try await lists.save(list(entries: 3, complete: false), for: plan.planId)

        let journal = try await executor.execute(plan: plan)

        XCTAssertEqual(spy.invocations, 0)
        XCTAssertTrue(
            journal.stepOutcomes[0]?.hasPrefix("refused_incomplete_restore_list") ?? false,
            "Got \(journal.stepOutcomes[0] ?? "nothing")"
        )
    }

    func testAnEmptyListIsNotAList() async throws {
        // A Mac with nothing registered has nothing to reset, and an empty
        // list far more often means the store was not read.
        let (executor, lists, spy) = makeExecutor()
        await executor.setToolRunner(spy.runner())
        let plan = resetPlan()
        try await lists.save(list(entries: 0, complete: true), for: plan.planId)

        let journal = try await executor.execute(plan: plan)

        XCTAssertEqual(spy.invocations, 0)
        XCTAssertTrue(journal.stepOutcomes[0]?.hasPrefix("refused_") ?? false)
    }

    func testAListFromADifferentPlanDoesNotCount() async throws {
        // The list that was shown and approved is the list that is checked,
        // not whatever was captured most recently.
        let (executor, lists, spy) = makeExecutor()
        await executor.setToolRunner(spy.runner())
        try await lists.save(list(entries: 4, complete: true), for: UUID())

        let journal = try await executor.execute(plan: resetPlan())

        XCTAssertEqual(spy.invocations, 0)
        XCTAssertTrue(journal.stepOutcomes[0]?.hasPrefix("refused_no_restore_list") ?? false)
    }

    func testAResetRunsOnceTheListIsThere() async throws {
        let (executor, lists, spy) = makeExecutor()
        await executor.setToolRunner(spy.runner())
        let plan = resetPlan()
        try await lists.save(list(entries: 4, complete: true), for: plan.planId)

        let journal = try await executor.execute(plan: plan)

        XCTAssertEqual(spy.invocations, 1)
        XCTAssertEqual(journal.stepOutcomes[0], "ok")
    }

    func testTheListIsOnDiskBeforeItCounts() async throws {
        // "I wrote it" is not the claim worth making. The reason it is
        // persisted at all is that the reset may succeed and Brim then not
        // be there: a crash, a quit, a closed laptop.
        let (_, lists, _) = makeExecutor()
        let planId = UUID()
        try await lists.save(list(entries: 2, complete: true), for: planId)

        let reopened = RestoreListStore(
            directoryURL: directory.appendingPathComponent("Lists")
        )
        let recovered = await reopened.load(planId: planId)

        XCTAssertEqual(recovered?.entries.count, 2)
        XCTAssertEqual(recovered?.entries.first?.name, "Item 0")
    }

    func testTheSummarySaysWhatWillHappen() {
        XCTAssertTrue(list(entries: 4, complete: true).summary.contains("4 background items"))
        XCTAssertTrue(list(entries: 0, complete: true).summary.contains("nothing to reset"))
        XCTAssertTrue(
            list(entries: 3, complete: false).summary.contains("could not read the whole")
        )
    }
}

/// Forgetting an installer receipt, and the things that are never forgotten.
final class ReceiptRulesTests: XCTestCase {

    func testAppleReceiptsAreRefused() {
        // Forgetting a system receipt can leave a later macOS update unable
        // to reason about what is installed, and it cannot be rebuilt.
        XCTAssertTrue(PrivilegedReceiptRemoval.belongsToApple("com.apple.pkg.CLTools"))
        XCTAssertTrue(PrivilegedReceiptRemoval.belongsToApple("COM.APPLE.pkg.Anything"))
        XCTAssertFalse(PrivilegedReceiptRemoval.belongsToApple("com.example.app"))

        XCTAssertThrowsError(
            try PrivilegedReceiptRemoval.check("com.apple.pkg.CLTools", receiptExists: { _ in true })
        ) { error in
            XCTAssertEqual(error as? PrivilegedReceiptRemoval.Refusal,
                           .belongsToApple("com.apple.pkg.CLTools"))
        }
    }

    func testOnlyAnIdentifierShapedStringGetsThrough() {
        // It reaches pkgutil as an argument and never touches a shell, but
        // a separator or a leading dash would still let it mean something
        // else.
        for bad in ["", "../../etc/passwd", "com.example/../../x", "-v", ".hidden",
                    "com example", "com.example;rm", String(repeating: "a", count: 300)] {
            XCTAssertFalse(PrivilegedReceiptRemoval.isWellFormed(bad), "accepted \"\(bad)\"")
        }
        for good in ["com.example.app", "com.example.app-1", "com_example_2"] {
            XCTAssertTrue(PrivilegedReceiptRemoval.isWellFormed(good), "rejected \"\(good)\"")
        }
    }

    func testAReceiptThatIsNotThereIsNotForgotten() {
        XCTAssertThrowsError(
            try PrivilegedReceiptRemoval.check("com.example.app", receiptExists: { _ in false })
        ) { error in
            XCTAssertEqual(error as? PrivilegedReceiptRemoval.Refusal,
                           .noSuchReceipt("com.example.app"))
        }
    }

    func testAGoodOneIsAllowed() {
        XCTAssertNoThrow(
            try PrivilegedReceiptRemoval.check("com.example.app", receiptExists: { name in
                name == "com.example.app.bom"
            })
        )
    }

    /// The daemon applies its own rules rather than trusting the app's, so
    /// both copies exist. Two copies is how three team identifiers ended
    /// up in one codebase, so they are held together here.
    func testTheAppAndTheDaemonAgreeAboutWhatIsAllowed() {
        for candidate in ["com.example.app", "com.apple.pkg.X", "../etc", "-v", "",
                          "com_example_2", "a.b-c"] {
            XCTAssertEqual(
                PackageReceipts.isWellFormed(candidate),
                PrivilegedReceiptRemoval.isWellFormed(candidate),
                "The two copies disagree about \"\(candidate)\""
            )
            XCTAssertEqual(
                PackageReceipts.belongsToApple(candidate),
                PrivilegedReceiptRemoval.belongsToApple(candidate),
                "The two copies disagree about whether \"\(candidate)\" is Apple's"
            )
        }
    }
}

/// Unlocking a file, and knowing which lock it is.
final class ImmutableFlagAgreementTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unlock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names {
                _ = lchflags(directory.appendingPathComponent(name).path, 0)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func lockedFile(_ name: String = "locked") throws -> (URL, TargetFingerprint) {
        let file = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(lchflags(file.path, UInt32(UF_IMMUTABLE)), 0)

        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        return (file, TargetFingerprint(
            dev: info.st_dev, ino: info.st_ino, mtime: Date(timeIntervalSince1970: 0)
        ))
    }

    func testAUserLockComesOff() throws {
        let (file, fingerprint) = try lockedFile()
        XCTAssertEqual(ArtifactLock.on(path: file.path), .user)

        try ImmutableFlag.clear(
            atPath: file.path, expectedDev: fingerprint.dev, expectedIno: fingerprint.ino
        )

        XCTAssertNil(ArtifactLock.on(path: file.path))
        XCTAssertNoThrow(try FileManager.default.removeItem(at: file))
    }

    func testAFileSwappedSinceThePlanIsRefused() throws {
        // The same anti-race binding as every other mutating operation:
        // the device and inode have to match what was planned.
        let (file, _) = try lockedFile()

        XCTAssertThrowsError(
            try ImmutableFlag.clear(atPath: file.path, expectedDev: 1, expectedIno: 999_999)
        ) { error in
            XCTAssertEqual(error as? ImmutableFlag.ClearError, .targetChanged)
        }
        XCTAssertEqual(ArtifactLock.on(path: file.path), .user, "It was unlocked anyway")
    }

    func testSomethingAbsentSaysSo() {
        XCTAssertThrowsError(
            try ImmutableFlag.clear(
                atPath: directory.appendingPathComponent("nope").path,
                expectedDev: 1, expectedIno: 1
            )
        ) { error in
            XCTAssertEqual(error as? ImmutableFlag.ClearError, .notThere)
        }
    }

    /// Detection is in `BrimCore` and clearing is in `BrimOps`, because
    /// `BrimCore` depends on nothing and the planner has to be able to
    /// ask. Two readings of the same flags, held to one answer.
    func testBothHalvesAgreeAboutWhatIsLocked() throws {
        let (locked, _) = try lockedFile("agree-locked")
        let plain = directory.appendingPathComponent("agree-plain")
        try Data("x".utf8).write(to: plain)

        XCTAssertEqual(ArtifactLock.on(path: locked.path), .user)
        XCTAssertNil(ArtifactLock.on(path: plain.path))

        // What BrimOps does about each is the other half of the same fact.
        var info = stat()
        XCTAssertEqual(lstat(locked.path, &info), 0)
        XCTAssertNoThrow(
            try ImmutableFlag.clear(
                atPath: locked.path, expectedDev: info.st_dev, expectedIno: info.st_ino
            ),
            "BrimCore called it clearable and BrimOps could not clear it"
        )
    }
}

/// Refusing to act on something that is running.
final class RunningApplicationTests: XCTestCase {

    private let running = [
        RunningApplications.Running(
            bundleIdentifier: "com.example.app", name: "Example",
            bundlePath: "/Applications/Example.app"
        ),
        RunningApplications.Running(
            bundleIdentifier: "com.example.app.helper", name: "Example Helper",
            bundlePath: "/Applications/Example.app/Contents/Library/LoginItems/Helper.app"
        ),
        RunningApplications.Running(
            bundleIdentifier: "com.other.thing", name: "Other",
            bundlePath: "/Applications/Other.app"
        ),
    ]

    func testTheApplicationItselfBlocks() {
        let refusal = RunningApplications.refusal(
            bundleID: "com.example.app", bundlePath: "/Applications/Example.app",
            among: running, selfBundleID: "com.sabharishhh.brim"
        )
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("Example") ?? false)
        // Both wordings have to explain themselves. A refusal that only
        // says no is a refusal people learn to route around.
        XCTAssertTrue(
            refusal?.contains("close") ?? false,
            "The refusal has to say why, not just that: \(refusal ?? "nothing")"
        )
    }

    func testOneRunningApplicationGetsTheSingularWording() {
        let one = [
            RunningApplications.Running(
                bundleIdentifier: "com.solo.app", name: "Solo",
                bundlePath: "/Applications/Solo.app"
            )
        ]
        let refusal = RunningApplications.refusal(
            bundleID: "com.solo.app", bundlePath: "/Applications/Solo.app",
            among: one, selfBundleID: "com.sabharishhh.brim"
        )
        XCTAssertEqual(refusal?.hasPrefix("Solo is running."), true, refusal ?? "nothing")
        XCTAssertTrue(refusal?.contains("writes its settings back out") ?? false)
    }

    func testAHelperInsideTheBundleBlocksToo() {
        // A login item at App.app/Contents/Library/LoginItems has its own
        // identifier and is just as able to rewrite what Brim removes.
        let refusal = RunningApplications.refusal(
            bundleID: "com.nothing.matching", bundlePath: "/Applications/Example.app",
            among: running, selfBundleID: "com.sabharishhh.brim"
        )
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("Example Helper") ?? false)
    }

    func testSomethingElseRunningDoesNotBlock() {
        XCTAssertNil(RunningApplications.refusal(
            bundleID: "com.somewhere.else", bundlePath: "/Applications/Elsewhere.app",
            among: running, selfBundleID: "com.sabharishhh.brim"
        ))
    }

    func testBrimDoesNotBlockItself() {
        // Uninstalling Brim from inside Brim is supported, and the app
        // quits itself once the plan has run.
        let brim = [
            RunningApplications.Running(
                bundleIdentifier: "com.sabharishhh.brim", name: "Brim",
                bundlePath: "/Applications/Brim.app"
            )
        ]
        XCTAssertNil(RunningApplications.refusal(
            bundleID: "com.sabharishhh.brim", bundlePath: "/Applications/Brim.app",
            among: brim, selfBundleID: "com.sabharishhh.brim"
        ))
    }

    func testAPathPrefixDoesNotMatchASibling() {
        // "/Applications/Example.app" must not swallow
        // "/Applications/Example.app.backup".
        let sibling = [
            RunningApplications.Running(
                bundleIdentifier: "com.example.backup", name: "Example Backup",
                bundlePath: "/Applications/Example.app.backup"
            )
        ]
        XCTAssertNil(RunningApplications.refusal(
            bundleID: "com.example.app", bundlePath: "/Applications/Example.app",
            among: sibling, selfBundleID: "com.sabharishhh.brim"
        ))
    }
}
