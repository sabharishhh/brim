import Foundation
import XCTest

/// Provisions disposable targets in the **real** user domains so the pipeline
/// can be exercised against the machine Brim actually runs on.
///
/// Synthetic fixtures (T-0.3) remain where correctness is proven: they are
/// deterministic and independent of whoever's Mac is running them. This
/// fixture exists for the class of defect those cannot reach — TCC refusals,
/// real Trash semantics, live scanning of protected domains — each of which
/// has already shipped a bug that every synthetic test passed.
///
/// Because it writes to real locations, every path is namespaced and every
/// removal is checked against that namespace before it happens. The fixture
/// will refuse to delete anything it did not create.
struct RealEnvironmentFixture {

    /// Every path this fixture creates contains this marker, and nothing
    /// without it may be removed.
    static let marker = "BrimHarness-"

    /// Real-environment tests touch the user's own disk and are therefore
    /// opt-in: `BRIM_REAL_ENV=1 swift test`. CI and ordinary runs skip them.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["BRIM_REAL_ENV"] == "1"
    }

    /// Skips the calling test unless real-environment runs were requested.
    static func requireEnabled(
        _ test: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard isEnabled else {
            throw XCTSkip(
                "Real-environment test. Run with BRIM_REAL_ENV=1 to exercise the actual machine.",
                file: file, line: line
            )
        }
    }

    let runID: String
    private(set) var created: [URL] = []

    init() {
        self.runID = "\(Self.marker)\(UUID().uuidString.prefix(8))"
    }

    // MARK: - Real domains

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/Library/Caches` — low cost of error, so the planner disposes of it
    /// permanently.
    var cachesDomain: URL { home.appendingPathComponent("Library/Caches") }

    /// `~/Library/Application Support` — medium cost, so it is trashed and
    /// stays recoverable.
    var applicationSupportDomain: URL { home.appendingPathComponent("Library/Application Support") }

    // MARK: - Provisioning

    /// Creates a disposable directory with a sparse payload: it reports the
    /// requested logical size to the scanner while occupying almost no disk,
    /// so a harness run costs kilobytes rather than gigabytes.
    mutating func makeTarget(
        in domain: URL,
        name: String,
        logicalBytes: Int64 = 64 * 1024 * 1024
    ) throws -> URL {
        let url = domain.appendingPathComponent("\(runID)-\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let blob = url.appendingPathComponent("payload.bin")
        FileManager.default.createFile(atPath: blob.path, contents: nil)
        let handle = try FileHandle(forWritingTo: blob)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(logicalBytes))

        try "Disposable Brim harness target. Safe to delete.\n"
            .write(to: url.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        created.append(url)
        return url
    }

    // MARK: - Teardown

    /// Removes everything this run created. Call from `tearDown`, and treat
    /// failures as test failures: a harness that leaks real directories into
    /// a user's Library is worse than one that fails.
    func cleanUp(file: StaticString = #filePath, line: UInt = #line) {
        for url in created {
            guard Self.isSafeToRemove(url) else {
                XCTFail("Refusing to remove \(url.path): outside the harness namespace", file: file, line: line)
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The one rule that keeps this harness from being dangerous: a path is
    /// removable only if the harness marker appears in its own last component.
    /// Checking the whole path would let `~/BrimHarness-x/../../Documents`
    /// through, so the component is checked directly.
    static func isSafeToRemove(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.lastPathComponent.hasPrefix(marker) else { return false }
        // Must still live under the user's Library, never anywhere else.
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library").standardizedFileURL
        return standardized.path.hasPrefix(library.path + "/")
    }
}
