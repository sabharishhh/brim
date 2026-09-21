import XCTest
@testable import BrimUI

/// The landing screen leads with what matters on this Mac.
///
/// The areas were listed in a fixed order, so the first card was whatever
/// the code declared first. On a Mac with nothing left over and forty
/// gigabytes of build caches, that meant leading with Leftovers and its
/// zero.
final class ReviewRankingTests: XCTestCase {

    private func finding(
        _ area: String, bytes: Int64 = 0, count: Int = 0,
        _ confidence: ReviewRanking.Confidence
    ) -> ReviewRanking.Finding {
        ReviewRanking.Finding(area: area, bytes: bytes, count: count, confidence: confidence)
    }

    func testTheBiggestRealFindingComesFirst() {
        let ranked = ReviewRanking.rank([
            finding("leftovers", bytes: 0, .named),
            finding("developer", bytes: 40_000_000_000, .certain),
            finding("applications", count: 86, .informational),
        ])
        XCTAssertEqual(ranked.first?.area, "developer")
    }

    func testAnAreaWithNothingToActOnSinks() {
        let ranked = ReviewRanking.rank([
            finding("applications", count: 86, .informational),
            finding("leftovers", bytes: 2_470_000_000, .named),
        ])
        XCTAssertEqual(ranked.map(\.area), ["leftovers", "applications"])
    }

    func testConfidenceSeparatesEqualImpact() {
        // The same number of bytes is worth more attention when the
        // evidence is a record that named an owner than when it is a
        // name match.
        let ranked = ReviewRanking.rank([
            finding("guessed", bytes: 1_000_000_000, .possible),
            finding("proven", bytes: 1_000_000_000, .named),
        ])
        XCTAssertEqual(ranked.first?.area, "proven")
    }

    func testCountsRankWhenThereAreNoBytes() {
        // Background jobs have no size. Ten stale ones should outrank one.
        let ranked = ReviewRanking.rank([
            finding("one", count: 1, .named),
            finding("ten", count: 10, .named),
        ])
        XCTAssertEqual(ranked.first?.area, "ten")
    }

    func testARealGigabyteOutranksAHandfulOfCountedThings() {
        let ranked = ReviewRanking.rank([
            finding("jobs", count: 10, .named),
            finding("caches", bytes: 4_000_000_000, .certain),
        ])
        XCTAssertEqual(ranked.first?.area, "caches")
    }

    func testEmptyAreasKeepTheirDeclaredOrder() {
        // Two areas with nothing in them must not swap places between one
        // redraw and the next.
        let input = [
            finding("first", .informational),
            finding("second", .informational),
            finding("third", .informational),
        ]
        XCTAssertEqual(ReviewRanking.rank(input).map(\.area), ["first", "second", "third"])
        XCTAssertEqual(ReviewRanking.rank(input).map(\.area),
                       ReviewRanking.rank(input).map(\.area))
    }

    func testNothingIsScored() throws {
        // No score, no percentage, no health colour. The order is the
        // whole of the ranking, because a number a person cannot check is
        // one they have to take on trust.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent("Brim/Views/Review/ReviewSummaryView.swift"),
            encoding: .utf8
        )
        // Code only. A comment saying "no score" is not a score, and a
        // test that cannot tell the difference fails on the note
        // explaining why it exists.
        let code = view.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
            .lowercased()

        for banned in ["finding.weight", "healthcolor", "% healthy", "healthscore"] {
            XCTAssertFalse(
                code.contains(banned),
                "The review screen shows \"\(banned)\". Only the order may express the ranking."
            )
        }
    }
}
