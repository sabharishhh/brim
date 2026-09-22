import XCTest
import BrimCore
import BrimOps
import BrimPrivileged
@testable import BrimService

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
