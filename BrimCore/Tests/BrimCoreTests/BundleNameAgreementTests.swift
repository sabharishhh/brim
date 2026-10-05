import BrimCore
@testable import BrimScan
import XCTest

/// The name an application answers to is read in two modules, and they have
/// to give one answer.
///
/// `LeftoversScanner` learned that a bundle's `CFBundleName` is what names
/// its support folder, and kept the knowledge to itself: it gathered the
/// name in a private array beside the identities rather than on `Identity`.
/// So the sweep correctly refused to offer up `Application Support/Code`
/// while Visual Studio Code was installed, and `LocationInventorySource`
/// correctly failed to remove the same 143 MB when it was uninstalled. One
/// fact, two readings, opposite halves of the same product disagreeing about
/// whether a folder belonged to anybody.
///
/// `Identity.searchNames` is now the single reading. These tests hold both
/// modules to it.
final class BundleNameAgreementTests: XCTestCase {
    /// A bundle whose file name and `CFBundleName` differ, which is the only
    /// case where the defect shows.
    private func makeBundle(
        fileName: String, bundleName: String, identifier: String
    ) throws -> (root: FileSystemRoot, bundle: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimNames-\(UUID().uuidString)")
        let applications = root.appendingPathComponent("Applications")
        let bundle = applications.appendingPathComponent("\(fileName).app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": bundleName,
            "CFBundleExecutable": fileName
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return (FileSystemRoot(rootURL: root), bundle)
    }

    /// **The 143 MB.** A folder named after `CFBundleName` has to be in the
    /// footprint the uninstall path builds.
    func testTheUninstallPathLooksForTheNameTheBundleCallsItself() async throws {
        let (root, bundle) = try makeBundle(
            fileName: "Visual Studio Code", bundleName: "Code", identifier: "com.microsoft.VSCode"
        )
        defer { try? FileManager.default.removeItem(at: root.rootURL) }

        let support = root.url(for: .userApplicationSupport).appendingPathComponent("Code")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let identity = await IdentityResolver(root: root).resolve(bundleURL: bundle)
        XCTAssertEqual(identity.bundleName, "Code", "CFBundleName was not read off the bundle.")

        let found = LocationInventorySource().findings(for: identity, in: root).evidence
        XCTAssertTrue(
            found.contains { $0.url.standardizedFileURL == support.standardizedFileURL },
            "Application Support/Code is Visual Studio Code's and is not in what the uninstall "
                + "path found. This is the 143 MB."
        )
    }

    /// A name match is Tier C wherever it comes from, and the row says it
    /// rests on a name. A short `CFBundleName` like "Code" is exactly the
    /// string that makes name matching dangerous. It is ticked only because
    /// it is the bundle's own name in its own data folder and nothing else
    /// installed answers to it, which `NameMatchingTests` holds.
    func testAFolderFoundByNameIsRatedAsANameMatch() async throws {
        let (root, bundle) = try makeBundle(
            fileName: "Visual Studio Code", bundleName: "Code", identifier: "com.microsoft.VSCode"
        )
        defer { try? FileManager.default.removeItem(at: root.rootURL) }

        let support = root.url(for: .userApplicationSupport).appendingPathComponent("Code")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let identity = await IdentityResolver(root: root).resolve(bundleURL: bundle)
        let engine = EvidenceEngine(sources: [
            LocationInventorySource(), BundleIdentifierComponentSource()
        ])
        let discovered = try await engine.discover(identity: identity, in: root)

        let match = discovered.evidence.first {
            $0.url.standardizedFileURL == support.standardizedFileURL
        }
        XCTAssertNotNil(match, "The folder was not found at all.")
        XCTAssertEqual(
            match?.tier, .C,
            "A folder matched on a name alone was rated \(match?.tier.rawValue ?? "nothing"). "
                + "The inventory has always said a name match is Tier C. Whether it is ticked is "
                + "decided from the name and the folder, not by raising the tier."
        )
    }

    /// A name match that is not clearly the application's own stays
    /// optional. The review can promote the row explicitly, so lowering its
    /// confidence does not make it unreachable. The folder named exactly for
    /// the application is ticked; one only beginning with its name is not.
    func testTheFileNameMatchCanBeIncludedWithoutBeingPreselected() async throws {
        let (root, bundle) = try makeBundle(
            fileName: "Figma", bundleName: "Figma", identifier: "com.figma.Desktop"
        )
        defer { try? FileManager.default.removeItem(at: root.rootURL) }

        let named = root.url(for: .userApplicationSupport).appendingPathComponent("Figma")
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        let support = root.url(for: .userApplicationSupport).appendingPathComponent("Figma-agent")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let identity = await IdentityResolver(root: root).resolve(bundleURL: bundle)
        let engine = EvidenceEngine(sources: [
            LocationInventorySource(), BundleIdentifierComponentSource()
        ])
        let discovered = try await engine.discover(identity: identity, in: root)

        let match = discovered.evidence.first {
            $0.url.standardizedFileURL.path == support.standardizedFileURL.path
        }
        XCTAssertEqual(match?.tier, .C)
        let footprint = try await FootprintProjector(engine: engine).project(identity: identity, in: root)
        let safety = SafetyEngine(
            safetyChecker: SafetyChecker(root: root, brimAppURL: root.rootURL.appendingPathComponent("Brim.app")),
            vetoEngine: TierSVetoEngine(root: root)
        )
        let evaluated = await safety.evaluate(footprint: footprint)
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let planner = Planner()
        let automatic = planner.createPlan(from: evaluated, intent: intent, engineVersion: EvidenceEngineRevision)
        XCTAssertTrue(automatic.steps.contains { $0.target == named.path })
        XCTAssertFalse(automatic.steps.contains { $0.target == support.path })
        XCTAssertEqual(automatic.excludedItems.first { $0.target == support.path }?.canBeTickedByHand, true)

        let manual = planner.createPlan(
            from: evaluated, intent: intent.tickingByHand([support.path]), engineVersion: EvidenceEngineRevision
        )
        XCTAssertTrue(manual.steps.contains { $0.target == support.path })
    }

    /// Both halves resolve the same set of names for the same bundle, which
    /// is the invariant that was broken rather than any one of its symptoms.
    func testBothHalvesAnswerToTheSameNames() async throws {
        let (root, bundle) = try makeBundle(
            fileName: "Visual Studio Code", bundleName: "Code", identifier: "com.microsoft.VSCode"
        )
        defer { try? FileManager.default.removeItem(at: root.rootURL) }

        let identity = await IdentityResolver(root: root).resolve(bundleURL: bundle)

        XCTAssertEqual(
            identity.searchNames, ["Visual Studio Code", "Code", "VSCode"],
            "Both names, file name first, then the identifier's own label, no duplicates."
        )
        XCTAssertEqual(
            LocationInventorySource.candidates(
                for: LocationInventory.Location(
                    domain: .userApplicationSupport, rule: .applicationName,
                    describes: "supporting files", sentence: "."
                ),
                identity: identity
            ),
            identity.searchNames,
            "The uninstall path searches something other than the names the identity carries."
        )
    }

    /// An application whose two names agree gets one candidate, not the same
    /// one twice, or every name-matched row appears in the plan in duplicate.
    func testANameThatAgreesWithItselfIsNotSearchedTwice() async throws {
        let (root, bundle) = try makeBundle(
            fileName: "Obsidian", bundleName: "Obsidian", identifier: "md.obsidian"
        )
        defer { try? FileManager.default.removeItem(at: root.rootURL) }

        let identity = await IdentityResolver(root: root).resolve(bundleURL: bundle)
        XCTAssertEqual(identity.searchNames, ["Obsidian"])
    }

    /// A bundle with no `CFBundleName` still answers to its file name. Most
    /// applications are this case and none of them may regress.
    func testABundleWithoutADeclaredNameStillAnswersToItsFileName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimNames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Applications/Plain.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.plain"],
            format: .xml, options: 0
        )
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        let identity = await IdentityResolver(root: FileSystemRoot(rootURL: root))
            .resolve(bundleURL: bundle)
        XCTAssertNil(identity.bundleName)
        XCTAssertEqual(identity.searchNames, ["Plain"])
    }

    /// SystemEQ for Mac (`com.denzam.SystemEQ`) kept its presets in
    /// `Application Support/SystemEQ`, which none of its displayed names
    /// reach, so the folder never appeared in its review. A generic last
    /// label, as in `dev.recordly.app`, adds nothing.
    func testTheIdentifiersProductLabelIsSearchedToo() {
        XCTAssertEqual(Identity(bundleID: "com.denzam.SystemEQ", name: "SystemEQ for Mac").searchNames,
                       ["SystemEQ for Mac", "SystemEQ"])
        XCTAssertEqual(Identity(bundleID: "dev.recordly.app", name: "Recordly").searchNames, ["Recordly"])
        XCTAssertEqual(Identity(bundleID: "com.figma.Desktop", name: "Figma").searchNames, ["Figma"])
    }
}
