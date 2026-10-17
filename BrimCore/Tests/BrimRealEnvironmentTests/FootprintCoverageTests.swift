import XCTest
import BrimCore
import BrimProtocol
@testable import BrimScan
@testable import BrimService

/// What the uninstall path finds for applications that are really
/// installed. Each test skips when the application it names is absent.
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

    /// Visual Studio Code's support folder is named for its `CFBundleName`,
    /// "Code", not its file name.
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

    /// Cache and log folders named for the application, not its identifier.
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

    /// An updater's `<identifier>.ShipIt` folder in Caches.
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

    /// Team identifiers resolve, or every team-prefixed rule is dead.
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

    /// The recent-documents record is the app's; the documents it names are
    /// not (`RecordedPathTests`).
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
            // Compared without case: macOS writes `com.microsoft.vscode.sfl4`.
            XCTAssertTrue(
                paths.contains { $0.lowercased() == record.lowercased() },
                "\(bundleID).sfl4 is \(name)'s own record and is not in its footprint."
            )
        }
        try XCTSkipIf(checked == 0, "No recent-document records for the measured applications.")
    }

    /// Data kept under `~/.local/share`, outside Library.
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

    /// A command linked into the bundle goes with the bundle.
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

    /// An app that declares no groups gets no other vendor app's containers
    /// selected on the team identifier alone.
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

    /// Not an assertion: prints what the engine finds so runs can be compared.
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
