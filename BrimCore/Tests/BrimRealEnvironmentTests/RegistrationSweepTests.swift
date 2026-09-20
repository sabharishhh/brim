import XCTest
import BrimCore
@testable import BrimScan

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
