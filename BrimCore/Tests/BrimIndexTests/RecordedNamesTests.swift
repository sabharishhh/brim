import BrimCore
@testable import BrimIndex
import Foundation
import Testing

/// Every name an app answered to is kept, and a later snapshot that learned
/// none does not erase them.
struct RecordedNamesTests {
    @Test func everyNameOutlivesTheApplication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try Index(dbManager: DatabaseManager(databaseURL: directory.appendingPathComponent("brim.sqlite")))

        let installed = InstallObservation(bundleID: "com.denzam.SystemEQ", name: "SystemEQ for Mac",
                                           names: ["SystemEQ for Mac", "SystemEQ"])
        _ = try await index.recordInstalled([installed])
        _ = try await index.recordInstalled([InstallObservation(bundleID: "com.denzam.SystemEQ",
                                                                name: "SystemEQ for Mac")])

        #expect(try await index.recordedAliases()["com.denzam.systemeq"] == ["SystemEQ for Mac", "SystemEQ"])
        #expect(try await index.recordedNames()["com.denzam.systemeq"] == "SystemEQ for Mac")
    }
}
