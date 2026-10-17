import Foundation

/// What a page found last time, kept so the next launch opens on it rather
/// than on an empty page. One file per page in Brim's caches folder, written
/// after each confirmed result; a file that does not decode is a miss. Read
/// back data is shown, never acted on, until this launch confirms it.
public struct PageCache<Value: Codable & Sendable>: Sendable {
    private struct Stored: Codable {
        let version: Int
        let savedAt: Date
        let value: Value
    }

    private let file: URL
    private let version: Int

    /// `version` changes whenever `Value`'s shape does, so an old file is never
    /// read as the new one.
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
    /// `~/Library/Caches/com.sabharishhh.brim/Pages`, deleted with Brim's caches
    /// when Brim removes itself.
    public static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.sabharishhh.brim/Pages", isDirectory: true)
    }
}
