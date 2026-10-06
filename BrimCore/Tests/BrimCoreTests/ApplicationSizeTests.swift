@testable import BrimScan
import Foundation
import XCTest

/// The Apps list measures every bundle at each launch, so the walk was
/// rewritten for speed. These hold it to the answer the old enumerator
/// gave: every file, hidden or not, and a link counted as itself, never
/// followed.
final class ApplicationSizeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func enumeratorSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0)
        }
        return total
    }

    func testTheWalkCountsWhatTheEnumeratorCounted() throws {
        let bundle = root.appendingPathComponent("Example.app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: macOS.appendingPathComponent("Example"))
        try Data(count: 10).write(to: bundle.appendingPathComponent("Contents/.hidden"))
        try Data(count: 300).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let outside = root.appendingPathComponent("outside.bin")
        try Data(count: 1_000_000).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent("Contents/link"), withDestinationURL: outside
        )

        let size = ApplicationInventory.size(of: bundle)
        XCTAssertEqual(size, enumeratorSize(of: bundle))
        XCTAssertLessThan(size, 1_000_000, "A link was followed into what it points at")
        XCTAssertGreaterThanOrEqual(size, 4096 + 10 + 300)
    }

    func testAMissingBundleMeasuresNothing() {
        XCTAssertEqual(ApplicationInventory.size(of: root.appendingPathComponent("Gone.app")), 0)
    }
}
