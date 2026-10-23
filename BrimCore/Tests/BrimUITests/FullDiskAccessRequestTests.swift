@testable import BrimUI
import Foundation
import XCTest

/// Turning on Full Disk Access usually goes through System Settings and a
/// relaunch. Brim remembers the request so the next launch returns to it,
/// and a running Brim offers to reopen itself.
@MainActor
final class FullDiskAccessRequestTests: XCTestCase {
    override func tearDown() {
        FullDiskAccess.clearRequest()
        super.tearDown()
    }

    private func request(_ origin: FullDiskAccess.Origin, secondsAgo: TimeInterval) {
        UserDefaults.standard.set(
            Date().timeIntervalSinceReferenceDate - secondsAgo, forKey: FullDiskAccess.requestedKey
        )
        UserDefaults.standard.set(origin.rawValue, forKey: FullDiskAccess.originKey)
    }

    func testARecentRequestIsPendingWithItsOrigin() {
        request(.settings, secondsAgo: 60)
        XCTAssertEqual(FullDiskAccess.pendingRequest, .settings)
    }

    func testAnOldRequestIsAnOrdinaryLaunch() {
        request(.window, secondsAgo: 45 * 60)
        XCTAssertNil(FullDiskAccess.pendingRequest, "A launch an hour later is not the end of a grant")
    }

    func testNoRequestIsNotRecent() {
        XCTAssertFalse(FullDiskAccess.isRecent(0))
    }

    /// Access arriving answers the request, so no page goes on offering a
    /// reopen that would change nothing.
    func testAccessArrivingClearsTheRequest() {
        request(.window, secondsAgo: 30)
        let model = FullDiskAccessModel(probe: { true })
        model.recheck()
        XCTAssertTrue(model.isGranted)
        XCTAssertFalse(model.hasRequested)
        XCTAssertNil(FullDiskAccess.pendingRequest)
    }

    /// Still off after the person went to System Settings: the switch may be
    /// on and waiting for a reopen, so the request is kept.
    func testStillOffKeepsTheRequest() {
        request(.window, secondsAgo: 30)
        let model = FullDiskAccessModel(probe: { false })
        model.recheck()
        XCTAssertFalse(model.isGranted)
        XCTAssertTrue(model.hasRequested)
        XCTAssertEqual(FullDiskAccess.pendingRequest, .window)
    }
}
