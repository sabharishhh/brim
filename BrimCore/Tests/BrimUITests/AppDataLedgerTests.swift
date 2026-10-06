@testable import BrimUI
import Foundation
import XCTest

/// Every app's data, counted once, and never what another row counts.
final class AppDataLedgerTests: XCTestCase {
    private let claude = AppDataLedger.App(name: "Claude", bundlePath: "/Applications/Claude.app", bundleBytes: 900)
    private let handler = AppDataLedger.App(
        name: "Claude Code URL Handler", bundlePath: "/Users/me/Applications/Handler.app", bundleBytes: 0
    )
    private let xcode = AppDataLedger.App(name: "Xcode", bundlePath: "/Applications/Xcode.app", bundleBytes: 10000)

    /// On this Mac both claimed `~/.claude`: summed as they came, 13 GB
    /// was counted twice and a 0 MB handler read as a 13 GB app.
    func testAFolderTwoAppsClaimGoesOnceToTheLargerBundle() {
        let data = AppDataLedger.attribute(apps: [claude, handler], claims: [
            .init(bundlePath: claude.bundlePath, path: "/Users/me/.claude", bytes: 13000),
            .init(bundlePath: handler.bundlePath, path: "/Users/me/.claude", bytes: 13000)
        ], countedElsewhere: [])
        XCTAssertEqual(data.map(\.dataBytes), [13000, 0])
    }

    func testTheBundleAndFoldersInsideOthersAreNotData() {
        let data = AppDataLedger.attribute(apps: [claude], claims: [
            .init(bundlePath: claude.bundlePath, path: "/Applications/Claude.app", bytes: 900),
            .init(bundlePath: claude.bundlePath, path: "/Users/me/Library/Caches/Claude", bytes: 300),
            .init(bundlePath: claude.bundlePath, path: "/Users/me/Library/Caches/Claude/Code Cache", bytes: 200)
        ], countedElsewhere: [])
        XCTAssertEqual(data.first?.dataBytes, 300, "The bundle is the Apps row, and a nested folder is in its parent")
    }

    func testWhatDeveloperCachesCountIsTakenOut() {
        let data = AppDataLedger.attribute(apps: [xcode], claims: [
            .init(bundlePath: xcode.bundlePath, path: "/Users/me/Library/Developer", bytes: 5000),
            .init(bundlePath: xcode.bundlePath, path: "/Users/me/Library/Developer/Xcode/DerivedData", bytes: 4000)
        ], countedElsewhere: [.init(path: "/Users/me/Library/Developer/Xcode/DerivedData", bytes: 4000)])
        XCTAssertEqual(data.first?.dataBytes, 1000, "DerivedData is the Developer caches row's, not Xcode's data")
    }
}

/// What changed between two visits, by subtraction.
final class SpaceHistoryTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "space-history-\(UUID().uuidString)")
    }

    private func snapshot(_ hoursAgo: Double, free: Int64, apps: [String: Int64] = [:]) -> SpaceSnapshot {
        SpaceSnapshot(date: Date().addingTimeInterval(-hoursAgo * 3600), used: 0, free: free,
                      rows: ["Developer caches": 10_000_000_000 - free], apps: apps)
    }

    func testVisitsWithinAnHourAreOneLook() {
        SpaceHistory.record(snapshot(3, free: 1), defaults)
        SpaceHistory.record(snapshot(0.5, free: 2), defaults)
        SpaceHistory.record(snapshot(0, free: 3), defaults)
        let all = SpaceHistory.load(defaults)
        XCTAssertEqual(all.map(\.free), [1, 3])
        XCTAssertEqual(SpaceHistory.previous(to: Date(), in: all)?.free, 1, "Never the look it is part of")
    }

    func testOnlyChangesWorthSayingAreListedLargestFirst() {
        let before = snapshot(24, free: 5_000_000_000, apps: ["Claude": 1_000_000_000, "Notes": 10_000_000])
        let after = snapshot(0, free: 3_000_000_000, apps: ["Claude": 4_000_000_000, "Notes": 20_000_000])
        let changes = SpaceHistory.changes(from: before, to: after)
        XCTAssertEqual(changes.map(\.title), ["Claude", "Developer caches"])
        XCTAssertEqual(changes.first?.bytes, 3_000_000_000)
    }
}
