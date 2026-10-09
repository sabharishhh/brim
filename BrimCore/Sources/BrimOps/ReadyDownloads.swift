import CryptoKit
import Foundation

/// A finished, checked download kept because its app would not quit.
///
/// Claude's update downloaded 384 MB, passed every check, and failed at the
/// last step because Claude stayed open; the download was thrown away with
/// the rest of the attempt, so Try Again fetched all of it again. It is now
/// kept here for a day, one folder per address, and the next attempt checks
/// it against the source's checksum again before using it.
enum ReadyDownloads {
    static func folder(in workspace: URL) -> URL {
        workspace.appendingPathComponent("Ready", isDirectory: true)
    }

    private static func slot(for url: URL, in workspace: URL) -> URL {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder(in: workspace).appendingPathComponent(key, isDirectory: true)
    }

    /// The kept download for this address, if one is younger than a day.
    static func file(for url: URL, in workspace: URL) -> URL? {
        discardExpired(in: workspace)
        let slot = slot(for: url, in: workspace)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: slot.path)) ?? []
        return names.first.map { slot.appendingPathComponent($0) }
    }

    /// Keeps `file`, moved rather than copied, unless it is already kept.
    static func keep(_ file: URL, for url: URL, in workspace: URL) {
        let slot = slot(for: url, in: workspace)
        guard file.deletingLastPathComponent().standardizedFileURL != slot.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: slot)
        try? FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: file, to: slot.appendingPathComponent(file.lastPathComponent))
    }

    static func forget(_ url: URL, in workspace: URL) {
        try? FileManager.default.removeItem(at: slot(for: url, in: workspace))
    }

    /// Kept downloads a day old go, as stopped ones do.
    static func discardExpired(in workspace: URL, now: Date = Date()) {
        let slots = (try? FileManager.default.contentsOfDirectory(
            at: folder(in: workspace), includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for slot in slots {
            let kept = (try? slot.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if now.timeIntervalSince(kept ?? .distantPast) > UpdateDownloader.resumeLifetime {
                try? FileManager.default.removeItem(at: slot)
            }
        }
    }
}
