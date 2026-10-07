@testable import BrimScan
import Foundation
import Testing

/// Measuring every bundle was 1.08 of the Apps list's 1.15 seconds at each
/// launch, for bundles that had not changed. An unchanged bundle is now
/// measured once; one that changed is measured again.
struct BundleSizesTests {
    private func bundle() throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-sizes-\(UUID().uuidString)/Demo.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data(count: 4096).write(to: app.appendingPathComponent("Contents/MacOS/Demo"))
        return app
    }

    @Test func `an unchanged bundle is measured once, across launches`() throws {
        let app = try bundle()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let file = app.deletingLastPathComponent().appendingPathComponent("sizes.json")
        var walks = 0
        let measure: (URL) -> Int64 = { url in
            walks += 1
            return ApplicationInventory.size(of: url)
        }
        let first = BundleSizes(file: file)
        #expect(first.size(of: app, measure: measure) == 4104)
        #expect(first.size(of: app, measure: measure) == 4104)
        first.keep(only: [app.path])
        let relaunched = BundleSizes(file: file)
        #expect(relaunched.size(of: app, measure: measure) == 4104)
        #expect(walks == 1)
    }

    /// An updater rewrites the executable and the Info.plist, so their
    /// folder's and the plist's times move and the size is read again.
    @Test func `a bundle whose contents changed is measured again`() throws {
        let app = try bundle()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let sizes = BundleSizes(file: nil)
        #expect(sizes.size(of: app, measure: ApplicationInventory.size(of:)) == 4104)
        let later = Date().addingTimeInterval(60)
        try Data(count: 8192).write(to: app.appendingPathComponent("Contents/MacOS/Demo2"))
        try FileManager.default.setAttributes([.modificationDate: later],
                                              ofItemAtPath: app.appendingPathComponent("Contents/MacOS").path)
        #expect(sizes.size(of: app, measure: ApplicationInventory.size(of:)) == 4104 + 8192)
    }
}
