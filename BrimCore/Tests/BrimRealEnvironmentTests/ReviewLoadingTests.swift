@testable import BrimCore
import BrimScan
import BrimService
import Foundation
import XCTest

/// Read-only timing probes for the removal-loading incident. They never
/// register a bundle, obtain approval or execute a removal.
final class ReviewLoadingTests: XCTestCase {
    func testInstalledBundleDiscoveryReportsItsActualCoverage() throws {
        try RealEnvironmentFixture.requireEnabled(self)
        let root = FileSystemRoot()
        let start = ContinuousClock.now
        let inventory = InstalledBundleInventory.read(in: root)
        print("Review inventory: \(start.duration(to: .now)), \(inventory.bundles.count) bundles, "
            +
            "\(inventory.completeness.timedOut.count) deadlines, \(inventory.completeness.unreadable.count) unreadable")
        print("Inventory deadlines: \(inventory.completeness.timedOut.prefix(3))")
        XCTAssertFalse(inventory.bundles.isEmpty)
    }

    func testInspectionAndReviewLoading() async throws {
        try RealEnvironmentFixture.requireEnabled(self)
        let bundle = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw XCTSkip("Probe app is absent.") }
        let root = FileSystemRoot()
        let identity = await IdentityResolver(root: root).resolve(bundleURL: bundle)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BrimService(root: root, brimAppURL: Bundle.main.bundleURL,
                                  planStoreDirectory: directory.appendingPathComponent("Plans"),
                                  journalStoreDirectory: directory.appendingPathComponent("Journals"))
        let start = ContinuousClock.now
        let footprint = try await service.inspect(identity: identity)
        let inspected = ContinuousClock.now
        let intent = PlanIntent(type: .uninstall, subjectIdentity: identity)
        let plan = try await service.plan(intent: intent)
        print("Review coverage: \(plan.scanCompleteness?.unreadable.count ?? 0) unreadable, "
            + "\(plan.scanCompleteness?.timedOut.count ?? 0) deadlines")
        let planned = ContinuousClock.now
        let optional = Set(plan.excludedItems.filter { $0.canBeTickedByHand == true }.map(\.target))
        _ = try await service.plan(intent: intent.tickingByHand(optional))
        print("Review stages: inspect \(start.duration(to: inspected)), "
            + "review \(inspected.duration(to: planned)), selection \(planned.duration(to: .now)), "
            + "\(footprint.items.count) items")
        let warm = ContinuousClock.now
        await service.preloadApplication(identity: identity, includeReview: true)
        _ = try await service.inspect(identity: identity)
        _ = try await service.plan(intent: intent)
        print("Review preloaded inspection and plan: \(warm.duration(to: .now))")
    }

    func testProtectionCoverageOfUnreadableClaimants() throws {
        try RealEnvironmentFixture.requireEnabled(self)
        let paths = ["/Applications/HBuilder.app",
                     "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app"]
        for path in paths {
            let bundle = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let start = ContinuousClock.now
            let signature: @Sendable (URL) -> BundleSurfaceReader.Signature = {
                BundleSurfaceReader.Signature.read($0, validate: false)
            }
            let (_, coverage) = BundleSurfaceReader.read(
                at: bundle, in: FileSystemRoot(), budget: ScanBudget(total: 5), protectingOnly: true,
                signature: signature
            )
            print("Claimant \(path): \(start.duration(to: .now)); "
                + "unreadable \(coverage.unreadable); deadlines \(coverage.timedOut); "
                + "signature gaps \(coverage.signatureGaps.prefix(4))")
        }
    }
}
