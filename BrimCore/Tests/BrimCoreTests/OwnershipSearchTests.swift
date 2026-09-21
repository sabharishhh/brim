import XCTest
@testable import BrimCore

/// The search that decides whether something is a leftover at all, and which
/// kind. Its ordering is the safety property: the cost of calling a live
/// app's data "orphaned" is a user deleting something they still need.
final class OwnershipSearchTests: XCTestCase {

    private func search(
        installedBundleIDs: Set<String> = [],
        installedNames: Set<String> = [],
        receipts: Set<String> = [],
        removedByBrim: Set<String> = [],
        launchServices: [String: [URL]] = [:],
        existing: Set<String> = []
    ) -> OwnershipSearch {
        OwnershipSearch(
            installedBundleIDs: installedBundleIDs,
            installedNames: installedNames,
            receiptBundleIDs: receipts,
            previouslyRemovedBundleIDs: removedByBrim,
            launchServicesLookup: { launchServices[$0] ?? [] },
            exists: { existing.contains($0.path) }
        )
    }

    // MARK: - Not a leftover

    func testAnInstalledApplicationOwnsItsData() {
        let s = search(installedBundleIDs: ["com.acme.app"])
        XCTAssertEqual(s.ownership(of: "com.acme.app"), .present(owner: URL(fileURLWithPath: "/")))
        XCTAssertNil(s.ownership(of: "com.acme.app").category, "An owned item is not a leftover")
    }

    func testADirectoryNamedAfterTheAppRatherThanItsIdentifierIsStillOwned() {
        // ~/Library/Application Support/Acme, not com.acme.app.
        let s = search(installedNames: ["acme"])
        XCTAssertNil(s.ownership(of: "Acme").category)
    }

    /// T-5.1 acceptance: the fixture's second-volume app is not reported as
    /// orphaned. An app on an external volume is installed software, and the
    /// walk that finds it covers every mounted volume.
    func testAnApplicationOnAnotherVolumeIsNotOrphaned() {
        let s = search(installedBundleIDs: ["com.acme.app"])
        XCTAssertNotEqual(s.ownership(of: "com.acme.app").category, .orphaned)
        XCTAssertNil(s.ownership(of: "com.acme.app").category)
    }

    func testLaunchServicesFindsAnOwnerTheDirectoryWalkMissed() {
        // Installed somewhere the walk does not reach, but macOS knows it and
        // the bundle is really there.
        let path = "/opt/weird/Acme.app"
        let s = search(
            launchServices: ["com.acme.app": [URL(fileURLWithPath: path)]],
            existing: [path]
        )
        XCTAssertNil(s.ownership(of: "com.acme.app").category, "A live registration is an owner")
    }

    // MARK: - Orphaned

    func testARegistrationPointingAtNothingIsTheOrphanEvidence() {
        // macOS recorded the app as installed and it has gone: exactly the
        // spec's definition of orphaned.
        let s = search(launchServices: ["com.acme.app": [URL(fileURLWithPath: "/Applications/Acme.app")]])
        let verdict = s.ownership(of: "com.acme.app")
        XCTAssertEqual(verdict.category, .orphaned)
        guard case .recordedButGone(let evidence) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertTrue(evidence.contains("/Applications/Acme.app"), "The evidence must name the record")
    }

    func testAReceiptForAbsentSoftwareIsOrphaned() {
        let s = search(receipts: ["com.acme.app"])
        XCTAssertEqual(s.ownership(of: "com.acme.app").category, .orphaned)
    }

    func testWhatBrimRemovedItselfIsOrphaned() {
        let s = search(removedByBrim: ["com.acme.app"])
        let verdict = s.ownership(of: "com.acme.app")
        XCTAssertEqual(verdict.category, .orphaned)
        guard case .recordedButGone(let evidence) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertTrue(evidence.contains("Brim removed"), evidence)
    }

    // MARK: - Unclaimed

    func testSomethingNobodyClaimsIsUnclaimedNotOrphaned() {
        // The two are never merged: unclaimed means the search came back
        // empty, which is not the same as knowing the owner has gone.
        let s = search()
        XCTAssertEqual(s.ownership(of: "com.mystery.thing").category, .unclaimed)
    }

    // MARK: - Ordering

    func testPresenceBeatsEveryRecordThatSaysOtherwise() {
        // A receipt, a Brim removal and a stale registration all say the
        // owner is gone. The app is on disk. Presence wins, because the cost
        // of getting this backwards is deleting live data.
        let path = "/Volumes/External/Acme.app"
        let s = search(
            installedBundleIDs: ["com.acme.app"],
            receipts: ["com.acme.app"],
            removedByBrim: ["com.acme.app"],
            launchServices: ["com.acme.app": [URL(fileURLWithPath: "/Applications/Gone.app")]],
            existing: [path]
        )
        XCTAssertNil(s.ownership(of: "com.acme.app").category, "An installed app is not a leftover")
    }

    func testALiveRegistrationBeatsAStaleOne() {
        // Two copies recorded, one still present: that is an owner, not an
        // orphan.
        let live = "/Applications/Acme.app"
        let s = search(
            launchServices: ["com.acme.app": [
                URL(fileURLWithPath: "/Users/someone/Old/Acme.app"),
                URL(fileURLWithPath: live)
            ]],
            existing: [live]
        )
        XCTAssertNil(s.ownership(of: "com.acme.app").category)
    }
}
