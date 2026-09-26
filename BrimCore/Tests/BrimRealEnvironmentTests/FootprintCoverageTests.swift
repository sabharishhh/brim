import XCTest
import BrimCore
import BrimProtocol
@testable import BrimScan
@testable import BrimService

/// What the uninstall path finds for applications that are really installed,
/// measured rather than assumed.
///
/// The leftovers sweep was audited and fixed; the uninstall path never was.
/// When it finally was, six installed applications produced plans that looked
/// complete and were not: Visual Studio Code's uninstall left 143 MB of its
/// own `Application Support` behind, because `Identity.name` is the bundle's
/// file name, "Visual Studio Code", and the folder is named after its
/// `CFBundleName`, which is "Code". `LeftoversScanner` had already learned to
/// read `CFBundleName`; `LocationInventorySource` had not, and nothing held
/// the two modules to one answer.
///
/// These are assertions about a real disk, so each one skips rather than
/// fails when the application it names is not installed. A machine without
/// Visual Studio Code is not a regression.
final class FootprintCoverageTests: XCTestCase {

    private var supportDirectory: URL!

    override func setUpWithError() throws {
        try RealEnvironmentFixture.requireEnabled(self)
        supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrimCoverage-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let supportDirectory {
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        super.tearDown()
    }

    private var root: FileSystemRoot { FileSystemRoot(rootURL: URL(fileURLWithPath: "/")) }

    private func makeService() -> BrimService {
        BrimService(
            root: root,
            brimAppURL: Bundle.main.bundleURL,
            planStoreDirectory: supportDirectory.appendingPathComponent("Plans"),
            journalStoreDirectory: supportDirectory.appendingPathComponent("Journals")
        )
    }

    /// The identity of an installed application, or nil when it is not here.
    private func identity(ofAppNamed name: String) async throws -> Identity? {
        let url = root.url(for: .applications).appendingPathComponent("\(name).app")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return await IdentityResolver(root: root).resolve(bundleURL: url)
    }

    private func footprintPaths(ofAppNamed name: String) async throws -> Set<String>? {
        guard let identity = try await identity(ofAppNamed: name) else { return nil }
        let footprint = try await makeService().inspect(identity: identity)
        return Set(footprint.items.map { $0.evidence.url.standardizedFileURL.path })
    }

    private func skipUnlessInstalled(_ name: String, _ paths: Set<String>?) throws -> Set<String> {
        guard let paths else {
            throw XCTSkip("\(name) is not installed on this Mac, so there is nothing to measure.")
        }
        return paths
    }

    // MARK: - The measured misses

    /// **The 143 MB.** Visual Studio Code is the one application of the six
    /// whose file name and `CFBundleName` differ, which is exactly why it was
    /// the one that leaked. `BundleIdentifierComponentSource` already matches
    /// `Application Support/<file name>`, so every application whose two names
    /// agree was found by accident rather than by rule.
    func testVisualStudioCodesSupportFolderIsInItsFootprint() async throws {
        let name = "Visual Studio Code"
        let paths = try skipUnlessInstalled(name, try await footprintPaths(ofAppNamed: name))
        let support = NSHomeDirectory() + "/Library/Application Support/Code"
        guard FileManager.default.fileExists(atPath: support) else {
            throw XCTSkip("This Mac has no Application Support/Code to find.")
        }
        XCTAssertTrue(
            paths.contains(support),
            "Uninstalling Visual Studio Code would leave Application Support/Code behind. "
            + "The folder is named after CFBundleName, which the uninstall path does not read."
        )
    }

    /// A cache or log folder named after the application rather than after its
    /// identifier is invisible: the inventory gives `Caches` and `Logs` an
    /// identifier rule and no name rule at all, so no amount of reading
    /// `CFBundleName` finds them until the rule exists.
    func testNameMatchedCachesAndLogsAreInTheFootprint() async throws {
        let home = NSHomeDirectory()
        let cases: [(app: String, path: String)] = [
            ("Antigravity", "\(home)/Library/Caches/Antigravity"),
            ("Antigravity", "\(home)/Library/Logs/Antigravity"),
            ("Claude", "\(home)/Library/Logs/Claude"),
        ]
        var measured: [String: Set<String>] = [:]
        var checked = 0
        for item in cases {
            guard FileManager.default.fileExists(atPath: item.path) else { continue }
            if measured[item.app] == nil {
                guard let paths = try await footprintPaths(ofAppNamed: item.app) else { continue }
                measured[item.app] = paths
            }
            checked += 1
            XCTAssertTrue(
                measured[item.app]?.contains(item.path) == true,
                "\(item.path) belongs to \(item.app) and is not in its footprint."
            )
        }
        try XCTSkipIf(checked == 0, "None of the measured cache or log folders are on this Mac.")
    }

    /// **Sparkle's helper.** An application installed by any route can switch
    /// to updating itself, and Squirrel leaves `<identifier>.ShipIt` in
    /// `Caches`. The inventory gives `Caches` an exact identifier rule, so the
    /// suffixed name never matches, and three of the six carry one.
    func testShipItCachesAreInTheFootprint() async throws {
        let home = NSHomeDirectory()
        let cases: [(app: String, id: String)] = [
            ("Visual Studio Code", "com.microsoft.VSCode"),
            ("Claude", "com.anthropic.claudefordesktop"),
            ("Antigravity", "com.google.antigravity"),
        ]
        var checked = 0
        for item in cases {
            let path = "\(home)/Library/Caches/\(item.id).ShipIt"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let paths = try await footprintPaths(ofAppNamed: item.app) else { continue }
            checked += 1
            XCTAssertTrue(
                paths.contains(path),
                "\(item.id).ShipIt is \(item.app)'s updater cache and is not in its footprint."
            )
        }
        try XCTSkipIf(checked == 0, "No ShipIt caches on this Mac.")
    }

    /// **Team identifiers.** Every team-prefixed rule in the inventory, and
    /// the whole of `TeamIDSource`, is dead code while `Identity.teamID` is
    /// nil. It was nil for every application on this Mac because
    /// `IdentityResolver` asked `SecCodeCopySigningInformation` for
    /// requirement information only, and the team identifier is signing
    /// information. `CodeSignature` in `BrimScan` asked correctly, so the same
    /// fact had two readings in two modules, which is the defect this
    /// repository has now hit twice.
    func testTeamIdentifiersResolveForInstalledApplications() async throws {
        let names = ["Visual Studio Code", "Claude", "Antigravity", "Figma", "Obsidian", "Recordly"]
        var checked = 0
        for name in names {
            guard let identity = try await identity(ofAppNamed: name) else { continue }
            checked += 1
            XCTAssertNotNil(
                identity.teamID,
                "\(name) is signed and codesign reports a team identifier, but Brim resolved none."
            )
        }
        try XCTSkipIf(checked == 0, "None of the measured applications are installed.")
    }

    /// **Six of six.** The recent-documents record is keyed exactly on the
    /// bundle identifier and no location named the directory it lives in, so
    /// every application measured was leaving one behind. The record goes;
    /// the documents it names are the person's and are never touched, which
    /// `RecordedPathTests` holds separately.
    func testRecentDocumentRecordsAreInTheFootprint() async throws {
        let directory = NSHomeDirectory()
            + "/Library/Application Support/com.apple.sharedfilelist"
            + "/com.apple.LSSharedFileList.ApplicationRecentDocuments"
        let names = ["Visual Studio Code", "Claude", "Antigravity", "Figma", "Obsidian", "Recordly"]
        var checked = 0
        for name in names {
            guard let identity = try await identity(ofAppNamed: name),
                  let bundleID = identity.bundleID
            else { continue }
            let record = "\(directory)/\(bundleID).sfl4"
            guard FileManager.default.fileExists(atPath: record) else { continue }
            guard let paths = try await footprintPaths(ofAppNamed: name) else { continue }
            checked += 1
            XCTAssertTrue(
                paths.contains(record),
                "\(bundleID).sfl4 is \(name)'s own record and is not in its footprint."
            )
        }
        try XCTSkipIf(checked == 0, "No recent-document records for the measured applications.")
    }

    /// **The 189 MB.** Claude keeps its real dataset under
    /// `~/.local/share/claude`, the way software written for Linux first
    /// does, and nothing in Brim read `$HOME` directly, so it was invisible
    /// to every evidence source at once.
    func testDataKeptOutsideTheLibraryFolderIsInTheFootprint() async throws {
        let home = NSHomeDirectory()
        let cases: [(app: String, path: String)] = [
            ("Claude", "\(home)/.local/share/claude"),
            ("Claude", "\(home)/.cache/claude"),
            ("Antigravity", "\(home)/.cache/antigravity"),
        ]
        var measured: [String: Set<String>] = [:]
        var checked = 0
        for item in cases {
            guard FileManager.default.fileExists(atPath: item.path) else { continue }
            if measured[item.app] == nil {
                guard let paths = try await footprintPaths(ofAppNamed: item.app) else { continue }
                measured[item.app] = paths
            }
            checked += 1
            XCTAssertTrue(
                measured[item.app]?.contains(item.path) == true,
                "\(item.path) is \(item.app)'s and is not in its footprint."
            )
        }
        try XCTSkipIf(checked == 0, "No XDG-style directories for the measured applications.")
    }

    /// **`/usr/local/bin/code`.** A command that is a link into the bundle
    /// goes with the bundle, or the Mac keeps a `code` that reports "no such
    /// file or directory" for as long as anybody leaves it there.
    func testACommandLinkedIntoTheBundleIsInTheFootprint() async throws {
        let link = "/usr/local/bin/code"
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil else {
            throw XCTSkip("This Mac has no /usr/local/bin/code.")
        }
        let paths = try skipUnlessInstalled(
            "Visual Studio Code", try await footprintPaths(ofAppNamed: "Visual Studio Code")
        )
        XCTAssertTrue(
            paths.contains(link),
            "/usr/local/bin/code points into the Visual Studio Code bundle and is not in its "
            + "footprint, so uninstalling would leave a command that cannot run."
        )
    }

    /// **The one that nearly shipped.** Visual Studio Code declares no
    /// application groups at all, so every `UBF8T346G9.*` folder in its
    /// footprint was matched on Microsoft's team identifier alone. Rated
    /// Tier B, as it was, uninstalling the editor offered to delete
    /// Microsoft Teams' data and the sign-in state shared by every Microsoft
    /// application on the Mac, with all of it ticked.
    ///
    /// It was invisible until the team identifier started resolving, because
    /// the source that claims these had been returning an empty array for
    /// every application since it was written.
    func testAnotherVendorApplicationsContainersAreVetoedNotSelected() async throws {
        let name = "Visual Studio Code"
        guard let identity = try await identity(ofAppNamed: name),
              let team = identity.teamID
        else { throw XCTSkip("\(name) is not installed on this Mac.") }

        let siblingScan = await TeamIDSource.otherApplicationFindings(
            sharing: team, besides: identity, in: root
        )
        try XCTSkipIf(
            siblingScan.identities.isEmpty,
            "No other \(team) application is installed, so there is no sharing to detect."
        )

        let footprint = try await makeService().inspect(identity: identity)
        let groupContainers = footprint.items.filter {
            $0.evidence.url.path.contains("/Group Containers/")
        }
        try XCTSkipIf(groupContainers.isEmpty, "No group containers under this team.")

        for item in groupContainers {
            XCTAssertEqual(
                item.evidence.tier, .S,
                "\(item.evidence.url.lastPathComponent) is shared with another installed "
                + "Microsoft application and was rated \(item.evidence.tier.rawValue). "
                + "Tier S is the veto; anything else can be ticked for removal."
            )
        }
    }

    // MARK: - The measurement itself

    /// Not an assertion, a record. Prints what the engine finds for each of
    /// the six so a before and an after can be compared by reading them
    /// rather than by remembering them.
    func testPrintTheMeasurement() async throws {
        let names = ["Visual Studio Code", "Claude", "Antigravity", "Figma", "Obsidian", "Recordly"]
        var report = "\n=== Footprint coverage ===\n"
        for name in names {
            guard let identity = try await identity(ofAppNamed: name) else {
                report += "\(name): not installed\n"
                continue
            }
            let footprint = try await makeService().inspect(identity: identity)
            report += "\n\(name)  [\(identity.bundleID ?? "no id")]  team=\(identity.teamID ?? "none")\n"
            report += "  \(footprint.items.count) items\n"
            for item in footprint.items.sorted(by: { $0.evidence.url.path < $1.evidence.url.path }) {
                report += "    \(item.evidence.url.path)\n"
            }
        }
        print(report)
    }
}
