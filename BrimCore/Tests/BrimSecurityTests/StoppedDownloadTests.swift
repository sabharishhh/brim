@testable import BrimOps
import Foundation
import Testing

/// A stopped download is kept so Update carries on from it, and deleted a
/// day later with the partial file URLSession holds for it, which deleting
/// the resume data alone would leave in the temporary folder.
struct StoppedDownloadTests {
    private func resume(in folder: URL, pointingAt partial: String, writtenAgo age: TimeInterval) throws -> URL {
        let file = folder.appendingPathComponent(UUID().uuidString)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["NSURLSessionResumeInfoTempFileName": partial], format: .binary, options: 0
        )
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                              ofItemAtPath: file.path)
        return file
    }

    @Test func `a day old stopped download goes, partial file and all, and a fresh one stays`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("brim-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let oldPartial = "CFNetworkDownload_\(UUID().uuidString).tmp"
        let newPartial = "CFNetworkDownload_\(UUID().uuidString).tmp"
        let temporary = FileManager.default.temporaryDirectory
        for name in [oldPartial, newPartial] {
            try Data(count: 1024).write(to: temporary.appendingPathComponent(name))
        }
        defer { try? FileManager.default.removeItem(at: temporary.appendingPathComponent(newPartial)) }
        let old = try resume(in: folder, pointingAt: oldPartial, writtenAgo: 25 * 3600)
        let fresh = try resume(in: folder, pointingAt: newPartial, writtenAgo: 60)

        UpdateDownloader.discardExpired(in: folder)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: temporary.appendingPathComponent(oldPartial).path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: temporary.appendingPathComponent(newPartial).path))
    }

    /// Resume data is a file anyone could write; what it names is deleted
    /// only inside the temporary folder.
    @Test func `resume data naming a file elsewhere deletes nothing there`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("brim-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/brim-resume-guard-\(UUID().uuidString)")
        try Data(count: 8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let file = folder.appendingPathComponent("evil")
        try PropertyListSerialization.data(
            fromPropertyList: ["NSURLSessionResumeInfoLocalPath": outside.path], format: .binary, options: 0
        ).write(to: file)

        UpdateDownloader.discard(file)

        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
