import XCTest
import BrimCore
@testable import BrimScan
import BrimOps

/// Registrations left behind by applications that are already gone.
final class RegistrationSweepTests: XCTestCase {

    override func setUpWithError() throws {
        try RealEnvironmentFixture.requireEnabled(self)
    }

    private var root: FileSystemRoot { FileSystemRoot(rootURL: URL(fileURLWithPath: "/")) }

    /// The fixtures prove the decoding; only the real store proves it decodes
    /// what macOS wrote.
    func testTheRealStoreDecodes() throws {
        let records = try XCTUnwrap(
            BTMStore().records(),
            "Could not read the store. Full Disk Access for the test runner?"
        )
        print("BTM store records: \(records.count)")
        for record in records {
            print("BTM   \(record.name ?? "unnamed") | \(record.type ?? "?") | \(record.disposition ?? "?")")
            print("BTM     id=\(record.identifier ?? "none") path=\(record.rawURLPath ?? "none")")
        }
        XCTAssertFalse(records.isEmpty, "A real Mac has background items")
        XCTAssertTrue(records.contains { $0.bundleIdentifier != nil },
                      "Records without identifiers means the keys are wrong")
        XCTAssertTrue(records.allSatisfy { $0.uuid.count == 36 }, "Each record carries its UUID")
    }

    /// The Background list grouped by application, with no duplicate rows for
    /// an app and its own tasks.
    func testTheListGroupsByApplication() async throws {
        let inventory = RegistrationInventory(surfaces: [
            LaunchdRegistrationSurface(), BackgroundItemSurface()
        ])
        let started = Date()
        let all = await inventory.all(in: root).filter { !$0.isSystemOwned }
        print("GROUP scan took \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        for group in RegistrationGroup.group(all) {
            print("GROUP \(group.displayName) [\(group.composition)] signedBy=\(group.signedBy ?? "mixed or unchecked")")
            for item in group.items {
                print("GROUP   \(item.label) | \(item.programPath ?? item.recordPath ?? "no path")")
                if let signing = item.signing { print("GROUP     signing: \(signing.sentence)") }
            }
        }
        XCTAssertFalse(all.isEmpty)
    }

    func testBackgroundItemsParseFromTheRealStore() async throws {
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
        for entry in all where entry.identifier.contains("keystone") {
            print("SWEEP KEYSTONE \(entry.identifier) | record=\(entry.recordPath ?? "none") | \(entry.evidence)")
        }
        print("SWEEP stale (program missing): \(stale.count)")
        for entry in stale.prefix(30) {
            print("SWEEP   \(entry.identifier)")
            print("SWEEP     program: \(entry.programPath ?? "none")")
            print("SWEEP     plist:   \(entry.recordPath ?? "none")")
        }

        XCTAssertFalse(all.isEmpty, "A real Mac always has launchd jobs")
    }
}

/// The leftovers surface against this machine. Every failure names an item.
final class LeftoversOnThisMachineTests: XCTestCase {

    override func setUpWithError() throws {
        try RealEnvironmentFixture.requireEnabled(self)
    }

    private func scan() async throws -> [Leftover] {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let inventory = RegistrationInventory(surfaces: [
            LaunchdRegistrationSurface(), BackgroundItemSurface()
        ])
        var stale: [String: String] = [:]
        for registration in await inventory.stale(in: root) {
            guard let owner = registration.owningBundleID else { continue }
            stale[owner] = registration.evidence
        }
        let scanner = LeftoversScanner(
            root: root,
            launchServicesLookup: { LaunchServicesRegistration.registeredApplicationURLs(forBundleID: $0) },
            staleRegistrationOwners: stale,
            protectedAppURL: ProcessInfo.processInfo.environment["BRIM_AUDIT_APP_URL"]
                .map { URL(fileURLWithPath: $0) }
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
            print("  ORPHAN  \(item.url.lastPathComponent): \(item.evidence)")
        }
        if ProcessInfo.processInfo.environment["BRIM_AUDIT_LEFTOVERS"] == "1" {
            for item in leftovers {
                print(
                    "  AUDIT  \(item.category.rawValue) | \(item.url.path) | "
                        + "\(item.potentialOwner?.name ?? "") | \(item.evidence)"
                )
            }
            print(
                "  GROUPS  \(orphaned.groupedByOwner().count) orphaned, "
                    + "\(unclaimed.groupedByOwner().count) unclaimed"
            )
        }

        XCTAssertFalse(leftovers.isEmpty, "A real Library should have something to say")
    }

    func testEveryOrphanNamesTheRecordThatOrphanedIt() async throws {
        // An orphan with no sentence naming its record is an assertion, not
        // evidence.
        for item in try await scan() where item.category == .orphaned {
            XCTAssertFalse(
                item.evidence.isEmpty,
                "Orphan with no evidence: \(item.url.path)"
            )
        }
    }

    func testNothingBelongingToAnInstalledApplicationIsListed() async throws {
        // Every leftover is cross-checked against Launch Services, independently
        // of the scan that produced it.
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
        // Orphaned is pre-selectable and unclaimed is not, so the two stay apart.
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

/// Measures whether consulting Launch Services changes the answer.
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
