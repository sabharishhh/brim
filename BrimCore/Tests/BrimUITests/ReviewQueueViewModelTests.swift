import XCTest
import BrimCore
import BrimProtocol
@testable import BrimUI

/// A service whose `leftovers()` returns exactly what the test asked for.
private struct StubService: BrimServiceProtocol {
    let leftoversResult: Result<[Leftover], Error>

    init(leftovers: [Leftover]) { self.leftoversResult = .success(leftovers) }
    init(error: Error) { self.leftoversResult = .failure(error) }

    func leftovers() async throws -> [Leftover] { try leftoversResult.get() }

    func inspect(identity: Identity) async throws -> Footprint { throw StubError.unimplemented }
    func plan(intent: PlanIntent) async throws -> Plan { throw StubError.unimplemented }
    func explain(planId: UUID) async throws -> String { throw StubError.unimplemented }
    func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalToken { throw StubError.unimplemented }
    func apply(planId: UUID, token: ApprovalToken) async throws { throw StubError.unimplemented }
    func verify(planId: UUID) async throws -> VerificationResult { throw StubError.unimplemented }
    func history() async throws -> [Plan] { [] }
    func undo(planId: UUID) async throws { throw StubError.unimplemented }
    func dumpBTM() async throws -> String { throw StubError.unimplemented }
    func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] { [] }
}

private enum StubError: Error, LocalizedError {
    case unimplemented
    case scanFailed

    var errorDescription: String? {
        switch self {
        case .unimplemented: return "unimplemented"
        case .scanFailed: return "scan failed"
        }
    }
}

private func leftover(_ path: String, size: Int64, category: Leftover.Category, owner: Identity? = nil) -> Leftover {
    Leftover(url: URL(fileURLWithPath: path), size: size, category: category, potentialOwner: owner)
}

@MainActor
final class ReviewQueueViewModelTests: XCTestCase {

    func testPopulateMapsLeftoversToFindings() async throws {
        let viewModel = ReviewQueueViewModel()
        let service = StubService(leftovers: [
            leftover("/Users/x/Library/Caches/Orphan", size: 100, category: .orphaned,
                     owner: Identity(bundleID: "com.example.orphan", name: "Orphan")),
            leftover("/Users/x/Library/Caches/loose-cache", size: 50, category: .unclaimed)
        ])

        await viewModel.populateProgressively(service: service)

        XCTAssertEqual(viewModel.totalCount, 2)
        XCTAssertEqual(viewModel.totalBytes, 150)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isPopulating)

        let orphan = try XCTUnwrap(viewModel.findings.first { $0.category == "Orphaned App" })
        XCTAssertEqual(orphan.title, "Orphan", "An owned leftover is titled after its owner")
        XCTAssertEqual(orphan.confidence, .guaranteed)

        let unclaimed = try XCTUnwrap(viewModel.findings.first { $0.category == "Unclaimed Leftover" })
        XCTAssertEqual(unclaimed.title, "loose-cache", "An unowned leftover falls back to its file name")
        XCTAssertEqual(unclaimed.confidence, .heuristic)
    }

    func testFindingsAreRankedByConfidenceWeightedSize() async {
        let viewModel = ReviewQueueViewModel()
        // The unclaimed item is larger, but its heuristic confidence (0.4)
        // discounts it below the guaranteed 1 MB orphan (1.0).
        let service = StubService(leftovers: [
            leftover("/tmp/big-unclaimed", size: 2_000_000, category: .unclaimed),
            leftover("/tmp/orphan", size: 1_000_000, category: .orphaned)
        ])

        await viewModel.populateProgressively(service: service)

        XCTAssertEqual(viewModel.findings.map(\.path), ["/tmp/orphan", "/tmp/big-unclaimed"])
    }

    func testPopulateAcrossBatchBoundaryKeepsEveryItemAndTotal() async {
        // More items than one publish batch, to catch off-by-one batching bugs.
        let count = 60
        let items = (0..<count).map {
            leftover("/tmp/item-\($0)", size: 10, category: .unclaimed)
        }
        let viewModel = ReviewQueueViewModel()

        await viewModel.populateProgressively(service: StubService(leftovers: items))

        XCTAssertEqual(viewModel.findings.count, count)
        XCTAssertEqual(viewModel.totalCount, count)
        XCTAssertEqual(viewModel.totalBytes, Int64(count * 10))
    }

    func testRepopulatingDoesNotDoubleCount() async {
        let service = StubService(leftovers: [leftover("/tmp/a", size: 42, category: .unclaimed)])
        let viewModel = ReviewQueueViewModel()

        await viewModel.populateProgressively(service: service)
        await viewModel.populateProgressively(service: service)

        XCTAssertEqual(viewModel.totalCount, 1)
        XCTAssertEqual(viewModel.totalBytes, 42)
    }

    func testRemoveItemsUpdatesCountAndTotal() async throws {
        let viewModel = ReviewQueueViewModel()
        await viewModel.populateProgressively(service: StubService(leftovers: [
            leftover("/tmp/a", size: 100, category: .unclaimed),
            leftover("/tmp/b", size: 25, category: .unclaimed)
        ]))

        let removed = try XCTUnwrap(viewModel.findings.first { $0.path == "/tmp/a" })
        viewModel.removeItems(with: [removed.id])

        XCTAssertEqual(viewModel.findings.map(\.path), ["/tmp/b"])
        XCTAssertEqual(viewModel.totalCount, 1)
        XCTAssertEqual(viewModel.totalBytes, 25)
    }

    func testScanFailureIsReportedAndLeavesQueueEmpty() async {
        let viewModel = ReviewQueueViewModel()

        await viewModel.populateProgressively(service: StubService(error: StubError.scanFailed))

        XCTAssertTrue(viewModel.findings.isEmpty)
        XCTAssertEqual(viewModel.totalCount, 0)
        XCTAssertFalse(viewModel.isPopulating)
        XCTAssertEqual(viewModel.errorMessage, "scan failed")
    }
}
