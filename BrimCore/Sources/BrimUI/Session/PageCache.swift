import Foundation

/// What a page found last time, kept on disk so the next launch opens on it
/// instead of on an empty page.
///
/// Every launch used to start from nothing: Apps waited about two seconds
/// for its list and Remnants nearly four for its scan, and a page with
/// nothing to show is a page that looks broken. One file per page, in
/// Brim's caches folder because everything in it can be found again,
/// written after each confirmed result. A file from another format, or one
/// that does not decode, is a miss, and the page scans as it would have.
///
/// A page shows what it loads from here and acts on none of it: nothing
/// read back is ticked or removable until this launch has confirmed it.
public struct PageCache<Value: Codable & Sendable>: Sendable {
    private struct Stored: Codable {
        let version: Int
        let savedAt: Date
        let value: Value
    }

    private let file: URL
    private let version: Int

    /// `version` changes whenever `Value`'s shape does, so an old file is
    /// never read as the new one.
    public init(_ name: String, version: Int, folder: URL = PageCaches.folder) {
        file = folder.appendingPathComponent(name + ".json")
        self.version = version
    }

    public func load() -> (value: Value, savedAt: Date)? {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == version
        else { return nil }
        return (stored.value, stored.savedAt)
    }

    /// Written off the main thread; a page does not wait for its own cache.
    public func save(_ value: Value, at date: Date = Date()) {
        let stored = Stored(version: version, savedAt: date, value: value)
        let file = file
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
    }
}

public enum PageCaches {
    /// `~/Library/Caches/com.sabharishhh.brim/Pages`, which Brim's own
    /// removal deletes with the rest of its caches folder.
    public static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.sabharishhh.brim/Pages", isDirectory: true)
    }
}
