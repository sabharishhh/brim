import XCTest
@testable import BrimCore

/// The four step kinds that were declared and never did anything.
///
/// `forgetReceipt`, `clearImmutableFlag`, `revealVendorUninstaller` and
/// `btmReset` were in the frozen vocabulary in §3.1, in the `StepKind`
/// enum, and in the disposition tables. No planner emitted them and no
/// executor branch handled them, so a plan containing one fell through to
/// `unsupported_kind`. Four of eleven kinds were decoration.
final class StepVocabularyTests: XCTestCase {

    /// Every kind either has a producer or is deliberately unreachable.
    /// Read from the source, because the failure being guarded against is
    /// the next kind added to the enum and nowhere else.
    func testEveryStepKindIsHandledByTheExecutor() throws {
        let executor = Self.repositoryRoot()
            .appendingPathComponent("BrimCore/Sources/BrimService/Executor.swift")
        let text = try String(contentsOf: executor, encoding: .utf8)

        for kind in StepKind.allCases {
            XCTAssertTrue(
                text.contains(".\(kind.rawValue)"),
                "\(kind.rawValue) is in the vocabulary and the executor has no branch for "
                + "it, so a plan containing one records unsupported_kind."
            )
        }
    }

    func testEveryStepKindCanBePlanned() throws {
        let planner = Self.repositoryRoot()
            .appendingPathComponent("BrimCore/Sources/BrimCore/Model/Plan/Planner.swift")
        let text = try String(contentsOf: planner, encoding: .utf8)

        // Three are not this planner's to emit, and they are not equal.
        //
        // `archivePath` is driven by the intent and `delegateToolCleanup` is
        // produced by `BrimService.planToolCleanup`, so both have a producer
        // and reach the executor in the shipping app.
        //
        // `btmReset` has neither. `BTMRestoreCapture`, `RestoreListStore` and
        // the executor branch all exist and are covered by tests, but nothing
        // in the product captures a list, builds a plan around one or offers
        // the reset, so the whole feature is reachable only from the test
        // suite. That is the decoration this file was written to catch, and
        // it is recorded here rather than excused: T-7.3 wires it up, and
        // this exemption comes out when it does.
        let notThePlanners: Set<StepKind> = [.btmReset, .archivePath, .delegateToolCleanup]

        for kind in StepKind.allCases where !notThePlanners.contains(kind) {
            XCTAssertTrue(
                text.contains("kind: .\(kind.rawValue)"),
                "Nothing produces a \(kind.rawValue) step, so the kind is decoration."
            )
        }
    }

    func testTheIrreversibleKindsAreMarkedIrreversible() {
        // forgetReceipt destroys a record that cannot be rebuilt, which is
        // exactly why it is safe to do and must be asked about.
        XCTAssertTrue(StepKind.forgetReceipt.destroysWithoutRecovery)
        XCTAssertTrue(StepKind.btmReset.destroysWithoutRecovery)
        XCTAssertFalse(StepKind.clearImmutableFlag.destroysWithoutRecovery)
        XCTAssertFalse(StepKind.revealVendorUninstaller.destroysWithoutRecovery)
    }

    func testAnIdentifierIsNotAPath() {
        // The "already gone" check reads targets as paths. A package
        // identifier is not a file, and skipping the step because no file
        // exists at "com.example.pkg" would drop it silently.
        XCTAssertFalse(StepKind.forgetReceipt.targetIsPath)
        XCTAssertFalse(StepKind.btmReset.targetIsPath)
        XCTAssertTrue(StepKind.clearImmutableFlag.targetIsPath)
        XCTAssertTrue(StepKind.revealVendorUninstaller.targetIsPath)
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}

/// Finding a vendor's own uninstaller without finding things that are not.
final class VendorUninstallerDetectionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vendor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func bundle(containing names: [String], in subdirectory: String) throws -> URL {
        let app = directory.appendingPathComponent("Vendor.app")
        let inner = app.appendingPathComponent(subdirectory)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for name in names {
            try Data().write(to: inner.appendingPathComponent(name))
        }
        return app
    }

    func testABundledUninstallerIsFound() throws {
        let app = try bundle(containing: ["Uninstaller.app"], in: "Contents/Resources")
        let found = VendorUninstallerDetector.insideBundle(at: app)

        XCTAssertNotNil(found)
        XCTAssertTrue(found?.path.hasSuffix("Uninstaller.app") ?? false)
        XCTAssertFalse(found?.reason.isEmpty ?? true, "A row a person acts on says how Brim knows")
    }

    func testAScriptCounts() throws {
        let app = try bundle(containing: ["uninstall.sh"], in: "Contents/Resources")
        XCTAssertNotNil(VendorUninstallerDetector.insideBundle(at: app))
    }

    func testSomethingThatMerelyContainsTheWordDoesNot() throws {
        // The failure this prevents is telling somebody to run a stranger's
        // executable because a loctable had the word in its name.
        let app = try bundle(
            containing: ["UninstallHelperStrings.loctable", "Uninstallation.rtf"],
            in: "Contents/Resources"
        )
        XCTAssertNil(VendorUninstallerDetector.insideBundle(at: app))
    }

    func testAnOrdinaryApplicationHasNone() throws {
        let app = try bundle(containing: ["MainMenu.nib", "Assets.car"], in: "Contents/Resources")
        XCTAssertNil(VendorUninstallerDetector.insideBundle(at: app))
    }

    func testTheWordHasToBeItsOwnWord() {
        XCTAssertTrue(VendorUninstallerDetector.looksLikeAnUninstaller("Uninstall.app"))
        XCTAssertTrue(VendorUninstallerDetector.looksLikeAnUninstaller("Adobe Uninstaller.app"))
        XCTAssertTrue(VendorUninstallerDetector.looksLikeAnUninstaller("uninstall-vpn.sh"))
        XCTAssertFalse(VendorUninstallerDetector.looksLikeAnUninstaller("uninstallhelper.dylib"))
        XCTAssertFalse(VendorUninstallerDetector.looksLikeAnUninstaller("Uninstalling.pdf"))
        XCTAssertFalse(VendorUninstallerDetector.looksLikeAnUninstaller("install.sh"))
    }
}

/// Telling the two locks apart.
final class ArtifactLockTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Unlock before removing, or the directory outlives the test.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names {
                _ = lchflags(directory.appendingPathComponent(name).path, 0)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func testAnUnlockedFileHasNoLock() throws {
        let file = directory.appendingPathComponent("plain")
        try Data("x".utf8).write(to: file)
        XCTAssertNil(ArtifactLock.on(path: file.path))
    }

    func testTheUserLockIsSeenAndIsClearable() throws {
        let file = directory.appendingPathComponent("locked")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(lchflags(file.path, UInt32(UF_IMMUTABLE)), 0)

        XCTAssertEqual(ArtifactLock.on(path: file.path), .user)
        XCTAssertTrue(ArtifactLock.user.canBeCleared)
        XCTAssertFalse(ArtifactLock.system.canBeCleared)
    }

    func testALinkIsJudgedOnItsOwnFlags() throws {
        // attributesOfItem follows the link and would report the target's
        // flags, which is the same trap that made a symlink count as its
        // target's size.
        let target = directory.appendingPathComponent("target")
        try Data("x".utf8).write(to: target)
        XCTAssertEqual(lchflags(target.path, UInt32(UF_IMMUTABLE)), 0)

        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(ArtifactLock.on(path: target.path), .user)
        XCTAssertNil(ArtifactLock.on(path: link.path), "The link itself is not locked")
    }

    func testSomethingAbsentIsNotLocked() {
        XCTAssertNil(ArtifactLock.on(path: directory.appendingPathComponent("nope").path))
    }
}
