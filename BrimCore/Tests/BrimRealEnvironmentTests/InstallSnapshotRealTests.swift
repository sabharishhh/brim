import BrimCore
@testable import BrimScan
import Foundation
import XCTest

/// A snapshot of the real inventory is quick enough to take while a person
/// waits, and two taken with nothing installed between them agree.
final class InstallSnapshotRealTests: XCTestCase {
    func testASnapshotIsQuickAndQuietWhenNothingIsInstalled() throws {
        try RealEnvironmentFixture.requireEnabled(self)
        let reader = InstallSnapshotReader()
        let clock = ContinuousClock()
        let started = clock.now
        let before = reader.take()
        let took = clock.now - started
        let after = reader.take()
        let result = InstallRecordingDiff.result(before: before, after: after, installed: [])
        print("snapshot: \(before.paths.count) paths, \(before.apps.count) apps, "
            + "\(before.backgroundItems.count) background items, \(took), unreadable \(before.unreadable)")
        print("noise: \(result.unclaimed.map(\.path))")
        XCTAssertLessThan(took, .seconds(3))
        XCTAssertTrue(result.apps.isEmpty)
        XCTAssertLessThanOrEqual(result.unclaimed.count, 3)
    }
}
