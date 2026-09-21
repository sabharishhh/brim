import XCTest
import BrimCore
import BrimProtocol
@testable import BrimUI

/// T-5.7's acceptance criterion: no code path deletes a container runtime
/// disk image or an Xcode archive.
///
/// These are the two that would hurt most. An archive holds the only
/// symbols that can read a crash report from something already shipped, and
/// a container disk image holds every image, container and volume Docker
/// has. Both sit in directories that look exactly like caches, which is why
/// the rule is written down rather than left to judgement.
@MainActor
final class DeveloperSafetyTests: XCTestCase {

    private func cache(
        _ name: String, _ tool: String, _ path: String,
        _ cost: DeveloperCache.Cost, cleanup: String? = nil
    ) -> DeveloperCache {
        DeveloperCache(
            name: name, tool: tool, url: URL(fileURLWithPath: path),
            sizeBytes: 1_000_000, cost: cost, explanation: "x", cleanupID: cleanup
        )
    }

    private func loaded(_ caches: [DeveloperCache]) async -> DeveloperModel {
        let model = DeveloperModel()
        await model.load(service: DeveloperStub(caches))
        return model
    }

    func testAnXcodeArchiveCannotBeSelectedOrPlanned() async {
        let archive = cache("Archives", "Xcode",
                            "/Users/x/Library/Developer/Xcode/Archives", .configured)
        let model = await loaded([archive])

        model.toggle(archive)
        XCTAssertTrue(model.selection.isEmpty, "Selecting it must be refused outright")

        model.selectRegenerable()
        XCTAssertTrue(model.selection.isEmpty, "Select all must skip it too")
        XCTAssertNil(model.removalIntent(requesterIdentity: "t"))
    }

    func testAContainerDiskImageCannotBeSelectedOrPlanned() async {
        let docker = cache("Build cache", "Docker",
                           "/Users/x/Library/Containers/com.docker.docker/Data/vms", .configured)
        let model = await loaded([docker])

        model.toggle(docker)
        model.selectRegenerable()

        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.removalIntent(requesterIdentity: "t"),
                     "Nothing in class three may reach a plan")
    }

    func testSimulatorDevicesAreClassThree() async {
        let devices = cache("Simulator devices", "Xcode",
                            "/Users/x/Library/Developer/CoreSimulator/Devices", .configured)
        let model = await loaded([devices])
        model.selectRegenerable()
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testAToolManagedStoreIsDelegatedRatherThanDeleted() async {
        // Removing a module cache by hand leaves the tool confused, so Brim
        // runs the tool's own command instead of touching the directory.
        let modcache = cache("Module cache", "Go", "/Users/x/go/pkg/mod",
                             .refetched, cleanup: "go.modcache")
        let model = await loaded([modcache])

        model.toggle(modcache)
        XCTAssertTrue(model.selection.isEmpty, "Brim does not delete these itself")
        XCTAssertNotNil(modcache.cleanupID, "It is delegated instead")
    }

    func testRegenerableCachesAreRemovable() async {
        // The rule has to let the useful case through, or it is just a
        // read only list.
        let derived = cache("Derived data", "Xcode",
                            "/Users/x/Library/Developer/Xcode/DerivedData", .rebuilt)
        let model = await loaded([derived])

        model.toggle(derived)
        XCTAssertEqual(model.selection.count, 1)

        let intent = model.removalIntent(requesterIdentity: "t")
        XCTAssertEqual(intent?.explicitTargets.map(\.path), [derived.url.path])
    }

    func testAMixedSelectionOnlyEverPlansTheRegenerableOnes() async {
        let derived = cache("Derived data", "Xcode", "/a/DerivedData", .rebuilt)
        let archive = cache("Archives", "Xcode", "/a/Archives", .configured)
        let model = await loaded([derived, archive])

        model.selectRegenerable()
        model.toggle(archive)

        let intent = model.removalIntent(requesterIdentity: "t")
        XCTAssertEqual(intent?.explicitTargets.map(\.path), ["/a/DerivedData"])
    }
}

private actor DeveloperStub: BrimServiceProtocol {
    let caches: [DeveloperCache]
    init(_ caches: [DeveloperCache]) { self.caches = caches }
    func developerCaches() async -> [DeveloperCache] { caches }

    func inspect(identity: Identity) async throws -> Footprint { throw Nope.no }
    func plan(intent: PlanIntent) async throws -> Plan { throw Nope.no }
    func explain(planId: UUID) async throws -> String { throw Nope.no }
    func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalToken { throw Nope.no }
    func apply(planId: UUID, token: ApprovalToken) async throws { throw Nope.no }
    func verify(planId: UUID) async throws -> VerificationResult { throw Nope.no }
    func history() async throws -> [Plan] { [] }
    func undo(planId: UUID) async throws { throw Nope.no }
    func dumpBTM() async throws -> String { "" }
    func installedApplications() async throws -> [InstalledApplication] { [] }
    func leftovers() async throws -> [Leftover] { [] }
    func recoverableItems() async throws -> [RecoverableItem] { [] }
    func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] { [] }
}

private enum Nope: Error { case no }
