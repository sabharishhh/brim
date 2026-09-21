import XCTest
import BrimCore
@testable import BrimScan
import BrimOps

/// The inverse query that motivated the product: registrations left behind by
/// applications that are already gone.
final class RegistrationSweepTests: XCTestCase {

    override func setUpWithError() throws {
        try RealEnvironmentFixture.requireEnabled(self)
    }

    private var root: FileSystemRoot { FileSystemRoot(rootURL: URL(fileURLWithPath: "/")) }

    func testBackgroundItemsParseFromTheRealDump() async throws {
        let surface = BackgroundItemSurface()
        let items = await surface.registrations(in: root)
        print("BTM parsed items: \(items.count)")
        for item in items {
            print("BTM   \(item.label) | id=\(item.identifier) | owner=\(item.owningBundleID ?? "nil")")
            print("BTM     path=\(item.programPath ?? "none") exists=\(item.targetExists) system=\(item.isSystemOwned)")
        }
        XCTAssertFalse(items.isEmpty, "A real Mac has background items")
    }

    func testReportsWhatIsRegisteredAndWhatIsStaleOnThisMachine() async throws {
        let inventory = RegistrationInventory(surfaces: [LaunchdRegistrationSurface()])
        let all = await inventory.all(in: root)
        let stale = await inventory.stale(in: root)

        print("SWEEP total launchd registrations: \(all.count)")
        print("SWEEP stale (program missing): \(stale.count)")
        for entry in stale.prefix(30) {
            print("SWEEP   \(entry.identifier)")
            print("SWEEP     program: \(entry.programPath ?? "none")")
            print("SWEEP     plist:   \(entry.recordPath ?? "none")")
        }

        XCTAssertFalse(all.isEmpty, "A real Mac always has launchd jobs")
    }
}

/// The leftovers surface, measured against this machine.
///
/// Synthetic fixtures can prove the ownership rules; only a real Library can
/// show what they classify. Every failure here names a specific item, so a
/// rule that is too eager shows up as "this belongs to something installed"
/// rather than as a number that looks plausible.
final class LeftoversOnThisMachineTests: XCTestCase {

    override func setUpWithError() throws {
        try RealEnvironmentFixture.requireEnabled(self)
    }

    private func scan() async throws -> [Leftover] {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let scanner = LeftoversScanner(
            root: root,
            launchServicesLookup: { LaunchServicesRegistration.registeredApplicationURLs(forBundleID: $0) }
        )
        return try await scanner.scanLeftovers()
    }

    func testReportsWhatItFoundAndHowItDecided() async throws {
        let leftovers = try await scan()
        let orphaned = leftovers.filter { $0.category == .orphaned }
        let unclaimed = leftovers.filter { $0.category == .unclaimed }

        print("""

        Leftovers on this machine
          orphaned:  \(orphaned.count)
          unclaimed: \(unclaimed.count)
          needing Full Disk Access: \(leftovers.filter { $0.capability != .ok }.count)
        """)
        for item in orphaned.prefix(12) {
            print("  ORPHAN  \(item.url.lastPathComponent) — \(item.evidence)")
        }

        XCTAssertFalse(leftovers.isEmpty, "A real Library should have something to say")
    }

    func testEveryOrphanNamesTheRecordThatOrphanedIt() async throws {
        // The category is a claim about evidence. An orphan with no sentence
        // is Brim asserting rather than showing, which is the one thing this
        // product may not do.
        for item in try await scan() where item.category == .orphaned {
            XCTAssertFalse(
                item.evidence.isEmpty,
                "Orphan with no evidence: \(item.url.path)"
            )
        }
    }

    func testNothingBelongingToAnInstalledApplicationIsListed() async throws {
        // The expensive mistake: offering to delete the data of software the
        // user still has. Cross-checks every leftover against Launch
        // Services independently of the scan that produced it.
        let leftovers = try await scan()
        var wronglyListed: [String] = []

        for item in leftovers {
            guard let bundleID = item.potentialOwner?.bundleID else { continue }
            let live = LaunchServicesRegistration
                .registeredApplicationURLs(forBundleID: bundleID)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if let owner = live.first {
                wronglyListed.append("\(item.url.lastPathComponent) → owned by \(owner.path)")
            }
        }

        XCTAssertEqual(
            wronglyListed, [],
            "Listed as leftovers despite a live owner:\n  " + wronglyListed.joined(separator: "\n  ")
        )
    }

    func testTheTwoCategoriesAreNeverMerged() async throws {
        // T-5.1 acceptance. Orphaned is pre-selectable, unclaimed is not, so
        // collapsing them would pre-select things nobody can attribute.
        let leftovers = try await scan()
        for item in leftovers {
            XCTAssertTrue(
                item.category == .orphaned || item.category == .unclaimed,
                "\(item.url.path) is neither"
            )
        }
        XCTAssertEqual(
            leftovers.map(\.id).count, Set(leftovers.map(\.id)).count,
            "An item appearing in both categories would be the merge this forbids"
        )
    }
}

/// Does consulting Launch Services actually change the answer on a real
/// machine, or is it ceremony? Measured rather than assumed.
final class LaunchServicesContributionTests: XCTestCase {

    override func setUpWithError() throws {
        try RealEnvironmentFixture.requireEnabled(self)
    }

    func testConsultingLaunchServicesRemovesFalseLeftovers() async throws {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))

        let withoutLS = try await LeftoversScanner(root: root).scanLeftovers()
        let withLS = try await LeftoversScanner(
            root: root,
            launchServicesLookup: { LaunchServicesRegistration.registeredApplicationURLs(forBundleID: $0) }
        ).scanLeftovers()

        let rescued = Set(withoutLS.map(\.id)).subtracting(withLS.map(\.id))
        print("""

        Launch Services contribution
          without it: \(withoutLS.count) leftovers
          with it:    \(withLS.count) leftovers
          rescued:    \(rescued.count) items that belong to software still installed
        """)
        for path in rescued.sorted().prefix(10) { print("  KEPT  \(path)") }

        XCTAssertLessThanOrEqual(
            withLS.count, withoutLS.count,
            "Consulting an extra ownership source can only ever remove leftovers, never add them"
        )
    }
}
