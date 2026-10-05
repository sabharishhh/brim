@testable import BrimCore
@testable import BrimScan
import Foundation
import XCTest

/// **SystemEQ for Mac.** Its removal left `Application Support/SystemEQ`
/// untouched and `Application Support/SystemEQ for Mac` unticked, in the
/// folder people open first to check a removal. Where Brim looked was
/// fine. How it compared names was not: a folder counted only when its name
/// was exactly one of the app's names, in the same case, and even then it
/// was never ticked. These hold the three parts of that: one comparison,
/// more of the names an app answers to, and ticking a folder clearly
/// named for it in its own data folders.
final class NameMatchingTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimNameMatching-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private var root: FileSystemRoot {
        FileSystemRoot(rootURL: rootURL, userName: "testuser")
    }

    private func makeBundle(file: String, name: String, identifier: String) throws -> URL {
        let bundle = root.url(for: .applications).appendingPathComponent("\(file).app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundleExecutable": file],
            format: .xml, options: 0
        ).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    private func makeFolder(_ domain: FileSystemRoot.Domain, _ name: String) throws -> URL {
        let folder = root.url(for: domain).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: folder.appendingPathComponent("state"))
        return folder
    }

    func testOneNameIsSpelledManyWaysOnDisk() {
        let key = NameKey.of("Visual Studio Code")
        for spelling in ["visual-studio-code", "VisualStudioCode", "visual_studio_code", "VISUAL STUDIO CODE"] {
            XCTAssertEqual(NameKey.of(spelling), key, spelling)
        }
        XCTAssertEqual(NameKey.of("Codex"), NameKey.of("codex"))
        XCTAssertNotEqual(NameKey.of("Codex"), NameKey.of("Code"))
    }

    func testAPlatformWordIsLeftOffTheFolderName() {
        XCTAssertEqual(Identity(bundleID: "com.denzam.SystemEQ", name: "SystemEQ for Mac").derivedNames, ["SystemEQ"])
        XCTAssertEqual(Identity(bundleID: "com.docker.docker", name: "Docker Desktop").derivedNames, ["Docker"])
        XCTAssertEqual(Identity(bundleID: "com.amazon.aiv.AIVApp", name: "Prime Video").derivedNames, ["AIVApp"])
        XCTAssertEqual(Identity(bundleID: "md.obsidian", name: "Obsidian").derivedNames, [])
    }

    /// Ticked when the name is one the app declares, in any spelling, or a
    /// derived one that is not an ordinary word. ChatGPT's identifier ends in
    /// `codex`, a word, so `Caches/Codex` stays a suggestion.
    func testOnlyAClearNameIsTicked() {
        let systemEQ = Identity(bundleID: "com.denzam.SystemEQ", name: "SystemEQ for Mac")
        XCTAssertTrue(systemEQ.isClearlyNamed("SystemEQ"))
        XCTAssertTrue(systemEQ.isClearlyNamed("systemeq-for-mac"))
        XCTAssertFalse(systemEQ.isClearlyNamed("SystemEQ Presets"))
        XCTAssertFalse(Identity(bundleID: "com.openai.codex", name: "ChatGPT").isClearlyNamed("Codex"))
        XCTAssertTrue(Identity(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", bundleName: "Code")
            .isClearlyNamed("Code"))
    }

    /// Found as it is spelled. Asking the volume for `codex` found `Codex`,
    /// and the row named a path that is not on the disk.
    func testAFolderSpelledDifferentlyIsFoundAsItIsSpelled() throws {
        try makeFolder(.userCaches, "Codex")
        try makeFolder(.userApplicationSupport, "systemeq")
        let chatGPT = LocationInventorySource().findings(
            for: Identity(bundleID: "com.openai.codex", name: "ChatGPT"), in: root
        ).evidence.map(\.url.lastPathComponent)
        XCTAssertTrue(chatGPT.contains("Codex"))
        XCTAssertFalse(chatGPT.contains("codex"))
        let systemEQ = LocationInventorySource().findings(
            for: Identity(bundleID: "com.denzam.SystemEQ", name: "SystemEQ for Mac"), in: root
        ).evidence.map(\.url.lastPathComponent)
        XCTAssertTrue(systemEQ.contains("systemeq"))
    }

    /// **The incident.** Both folders go with the app, unasked.
    func testSystemEQsSupportFoldersAreRemovedWithIt() async throws {
        let bundle = try makeBundle(file: "SystemEQ for Mac", name: "SystemEQ for Mac",
                                    identifier: "com.denzam.SystemEQ")
        let presets = try makeFolder(.userApplicationSupport, "SystemEQ")
        let named = try makeFolder(.userApplicationSupport, "SystemEQ for Mac")
        let elsewhere = try makeFolder(.userServices, "SystemEQ")

        let plan = try await automaticPlan(for: bundle)
        XCTAssertTrue(plan.steps.contains { $0.target == presets.path }, "Application Support/SystemEQ stayed")
        XCTAssertTrue(plan.steps.contains { $0.target == named.path }, "Application Support/SystemEQ for Mac stayed")
        XCTAssertFalse(plan.steps.contains { $0.target == elsewhere.path },
                       "A name outside the data folders was ticked")
    }

    /// A folder two installed applications both answer to belongs to neither
    /// by default, now that a name match can be ticked.
    func testAFolderAnotherInstalledAppIsNamedForIsLeftAlone() async throws {
        let bundle = try makeBundle(file: "Studio Pro", name: "Studio", identifier: "com.example.pro")
        try makeBundle(file: "Studio", name: "Studio", identifier: "com.other.studio")
        let shared = try makeFolder(.userApplicationSupport, "Studio")

        let plan = try await automaticPlan(for: bundle)
        XCTAssertFalse(plan.steps.contains { $0.target == shared.path })
        let reason = plan.excludedItems.first { $0.target == shared.path }?.reason ?? ""
        XCTAssertTrue(reason.contains("Studio"), reason)
    }

    /// Once the app is gone its bundle cannot be read, so the sweep has only
    /// what history kept. It used to keep one name.
    func testARemovedAppsRecordedNamesFindWhatItLeft() async throws {
        let kept = try makeFolder(.userApplicationSupport, "SystemEQ")
        let leftovers = try await LeftoversScanner(root: root).scanLeftovers(
            knownPastBundleIDs: ["com.example.tool"], knownNames: ["com.example.tool": "Tool for Mac"],
            knownAliases: ["com.example.tool": ["Tool for Mac", "SystemEQ"]]
        )
        XCTAssertTrue(leftovers.contains { $0.url.lastPathComponent == kept.lastPathComponent })
    }

    /// A folder that is itself what a removed app was called is that app's,
    /// though a longer name begins with it. `SystemEQ` was opened as though
    /// it were a developer's folder, because the app was "SystemEQ for Mac",
    /// and `presets` inside it was judged on its own and never offered.
    func testAFolderNamedForARemovedAppIsNotTakenForADevelopersFolder() async throws {
        let presets = try makeFolder(.userApplicationSupport, "SystemEQ/presets")
        let leftovers = try await LeftoversScanner(root: root).scanLeftovers(
            knownPastBundleIDs: ["com.denzam.SystemEQ"], knownNames: ["com.denzam.systemeq": "SystemEQ for Mac"]
        )
        let offered = leftovers.map(\.url.standardizedFileURL.path)
        XCTAssertTrue(offered.contains(presets.deletingLastPathComponent().standardizedFileURL.path), "\(offered)")
    }

    /// **ChatGPT's own folder offered while it ran.** "Codex Computer Use"
    /// begins with "Codex", so `Application Support/Codex` was opened as a
    /// developer's folder, and Chromium's lock links inside it, which point
    /// at tokens rather than files, were each listed as a removed app.
    func testAnInstalledAppsFolderIsNeverOpenedAndItsLocksAreNotLeftovers() async throws {
        try makeBundle(file: "ChatGPT", name: "ChatGPT", identifier: "com.openai.codex")
        try makeBundle(file: "Codex Computer Use", name: "Codex Computer Use", identifier: "com.openai.sky.CUAService")
        let codex = try makeFolder(.userApplicationSupport, "Codex")
        for (link, token) in [("SingletonLock", "host.local-8658"), ("RunningChromeVersion", "154.0.8037.98:1")] {
            try FileManager.default.createSymbolicLink(atPath: codex.appendingPathComponent(link).path,
                                                       withDestinationPath: token)
        }
        let stray = root.url(for: .userApplicationSupport).appendingPathComponent("SingletonCookie")
        try FileManager.default.createSymbolicLink(atPath: stray.path, withDestinationPath: "1365608545")

        let leftovers = try await LeftoversScanner(root: root).scanLeftovers()
        XCTAssertFalse(leftovers.contains { $0.url.path.hasPrefix(codex.path) }, "\(leftovers.map(\.url.path))")
        XCTAssertFalse(leftovers.contains { $0.url.lastPathComponent == "SingletonCookie" && $0.category == .orphaned },
                       "A lock link was read as a command whose app has gone")
    }

    func testTheICloudCacheIsInTheFootprint() throws {
        let cache = try makeFolder(.userCloudKitCaches, "developer.apple.wwdc-Release")
        let found = LocationInventorySource().findings(
            for: Identity(bundleID: "developer.apple.wwdc-Release", name: "Developer"), in: root
        ).evidence.map(\.url.path)
        XCTAssertTrue(found.contains(cache.path))
    }

    private func automaticPlan(for bundle: URL) async throws -> Plan {
        let identity = await IdentityResolver(root: root).resolve(bundleURL: bundle)
        let engine = EvidenceEngine(sources: [LocationInventorySource(), BundleIdentifierComponentSource()])
        let footprint = try await FootprintProjector(engine: engine).project(identity: identity, in: root)
        let safety = SafetyEngine(
            safetyChecker: SafetyChecker(root: root, brimAppURL: rootURL.appendingPathComponent("Brim.app")),
            vetoEngine: TierSVetoEngine(root: root)
        )
        let evaluated = await safety.evaluate(footprint: footprint)
        return Planner().createPlan(from: evaluated, intent: PlanIntent(type: .uninstall, subjectIdentity: identity),
                                    engineVersion: EvidenceEngineRevision)
    }
}
