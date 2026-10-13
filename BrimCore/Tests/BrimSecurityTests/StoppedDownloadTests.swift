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

/// Claude's update downloaded 384 MB, passed every check and stopped only
/// because Claude stayed open; Try Again downloaded all of it again. A
/// download whose app would not quit is kept for a day and used once more.
struct ReadyDownloadTests {
    private let url = URL(string: "https://example.com/releases/Demo-2.0.zip")!

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("brim-ready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func `a download kept for its app is found for the same address, and only that one`() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let download = workspace.appendingPathComponent("attempt/Demo.zip")
        try FileManager.default.createDirectory(at: download.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(count: 64).write(to: download)

        ReadyDownloads.keep(download, for: url, in: workspace)

        let kept = ReadyDownloads.file(for: url, in: workspace)
        #expect(kept?.lastPathComponent == "Demo.zip")
        let other = try #require(URL(string: "https://example.com/Other.zip"))
        #expect(ReadyDownloads.file(for: other, in: workspace) == nil)
        ReadyDownloads.forget(url, in: workspace)
        #expect(ReadyDownloads.file(for: url, in: workspace) == nil)
    }

    @Test func `a kept download goes once it is a day old`() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let download = workspace.appendingPathComponent("Demo.zip")
        try Data(count: 64).write(to: download)
        ReadyDownloads.keep(download, for: url, in: workspace)
        let slot = try #require(ReadyDownloads.file(for: url, in: workspace)).deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)],
                                              ofItemAtPath: slot.path)

        #expect(ReadyDownloads.file(for: url, in: workspace) == nil)
        #expect(!FileManager.default.fileExists(atPath: slot.path))
    }
}
