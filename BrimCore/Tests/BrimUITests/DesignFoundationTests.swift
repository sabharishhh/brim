@testable import BrimUI
import XCTest

/// The rules under the redesign's icons and "new" dots.
@MainActor
final class DesignFoundationTests: XCTestCase {
    private func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("design-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testMonogramsReadTheWayAPersonWouldAbbreviate() {
        XCTAssertEqual(Monogram(name: "Visual Studio Code").letters, "VS")
        XCTAssertEqual(Monogram(name: "OneDrive").letters, "OD")
        XCTAssertEqual(Monogram(name: "figma").letters, "F")
        XCTAssertEqual(Monogram(name: "com.vendor.tool").letters, "T", "Not the registry")
        XCTAssertEqual(Monogram(name: "").letters, "?")
    }

    func testAnOwnerIsTheSameColourEverywhere() {
        XCTAssertEqual(Monogram(name: "Figma").hue, Monogram(name: "figma").hue)
        XCTAssertTrue((0 ..< Monogram.hueCount).contains(Monogram(name: "Docker").hue))
    }

    func testTheIconRuleTakesTheFirstMatch() {
        let owner = URL(fileURLWithPath: "/Applications/Figma.app")
        let caches = URL(fileURLWithPath: "/Users/me/Library/Caches/com.figma.Desktop")
        let driver = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Gone.driver")
        let all: (URL) -> Bool = { _ in true }
        let none: (URL) -> Bool = { _ in false }

        let row = IconSubject(
            name: "Caches", kind: .folder, path: caches,
            ownerName: "Figma", ownerBundleID: "com.figma.Desktop", ownerURL: owner
        )
        XCTAssertEqual(IconResolver.source(for: row, exists: all, remembered: { _ in true }), .bundle(owner))
        XCTAssertEqual(
            IconResolver.source(for: row, exists: { $0 != owner }, remembered: { _ in true }),
            .remembered(bundleID: "com.figma.Desktop"), "A removed owner keeps its face"
        )
        let forgotten: (String) -> Bool = { _ in false }
        XCTAssertEqual(IconResolver.source(for: row, exists: { $0 != owner }, remembered: forgotten), .finder(caches))
        XCTAssertEqual(
            IconResolver.source(for: row, exists: none, remembered: forgotten), .monogram(Monogram(name: "Figma"))
        )

        let plugIn = IconSubject(name: "Gone", kind: .file, path: driver)
        XCTAssertEqual(IconResolver.source(for: plugIn, exists: all, remembered: { _ in false }), .bundle(driver))

        let agent = IconSubject(
            name: "com.vendor.updater", kind: .launchAgent,
            path: URL(fileURLWithPath: "/Library/LaunchAgents/com.vendor.updater.plist")
        )
        XCTAssertEqual(
            IconResolver.source(for: agent, exists: all, remembered: { _ in false }), .symbol(.launchAgent),
            "Not Finder's plist icon, which every agent would share"
        )
    }

    func testOneSnapshotMeansNothingToCompareNotNothingNew() throws {
        let file = try scratch().appendingPathComponent("visits.json")
        let first = VisitMemory(file: file)
        XCTAssertEqual(first.newItems(in: "leftovers", current: ["a", "b"]), [])
        first.acknowledge("leftovers", current: ["a", "b"])

        let next = VisitMemory(file: file)
        XCTAssertTrue(next.hasSnapshot(of: "leftovers"))
        XCTAssertEqual(next.newItems(in: "leftovers", current: ["a", "b", "c"]), ["c"])
        XCTAssertEqual(next.newItems(in: "apps", current: ["x"]), [], "Never looked is not new")
    }

    func testTheVisitBeforeThisOneIsTheOnePeopleMean() throws {
        let file = try scratch().appendingPathComponent("visits.json")
        let monday = Date(timeIntervalSince1970: 1_000_000)
        VisitMemory(file: file).begin(now: monday)

        let today = VisitMemory(file: file)
        today.begin(now: monday.addingTimeInterval(86400))
        XCTAssertEqual(today.lastVisit, monday)
    }

    func testAKeptItemStaysKept() throws {
        let file = try scratch().appendingPathComponent("decisions.json")
        DecisionStore(file: file).keep(["/Users/me/Library/Caches/Tool"])
        let later = DecisionStore(file: file)
        XCTAssertTrue(later.isKept("/Users/me/Library/Caches/Tool"))
        later.unkeep(["/Users/me/Library/Caches/Tool"])
        XCTAssertFalse(DecisionStore(file: file).isKept("/Users/me/Library/Caches/Tool"))
    }
}
