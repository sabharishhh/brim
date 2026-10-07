import Foundation

/// Each app bundle's size, remembered with what the bundle looked like when
/// it was measured, so an unchanged bundle is not walked again.
///
/// Measuring every file of every bundle was nearly all of the Apps list's
/// wait: 1.08 of 1.15 seconds for 87 apps on this Mac, at every launch, for
/// bundles that had not changed since the last one. A bundle is measured
/// again when anything that changes with its contents changes: the folder's
/// identity (an update that swaps the bundle gives it a new one), or the
/// modification time of the bundle, its `Contents`, its `Info.plist` or its
/// `MacOS` folder. Kept in Brim's caches folder, because all of it can be
/// measured again.
public final class BundleSizes: @unchecked Sendable {
    struct Fingerprint: Codable, Equatable {
        let device: Int64
        let inode: UInt64
        let times: [Double]
    }

    struct Entry: Codable {
        let fingerprint: Fingerprint
        let bytes: Int64
    }

    private let file: URL?
    private let lock = NSLock()
    private var entries: [String: Entry]
    private var changed = false

    /// Nil keeps sizes for this process only, which is what a test wants.
    public init(file: URL?) {
        self.file = file
        entries = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// `~/Library/Caches/com.sabharishhh.brim/bundle-sizes.json`.
    public static var standardFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.sabharishhh.brim/bundle-sizes.json")
    }

    /// The bundle's size, measured with `measure` only if it changed.
    func size(of bundle: URL, measure: (URL) -> Int64) -> Int64 {
        let key = bundle.path
        guard let fingerprint = Self.fingerprint(of: bundle) else { return measure(bundle) }
        lock.lock()
        let known = entries[key]
        lock.unlock()
        if let known, known.fingerprint == fingerprint {
            return known.bytes
        }
        let bytes = measure(bundle)
        lock.lock()
        entries[key] = Entry(fingerprint: fingerprint, bytes: bytes)
        changed = true
        lock.unlock()
        return bytes
    }

    /// Forgets bundles that are no longer listed and writes the rest, if
    /// anything changed.
    func keep(only bundles: Set<String>) {
        lock.lock()
        let before = entries.count
        entries = entries.filter { bundles.contains($0.key) }
        let write = changed || entries.count != before
        changed = false
        let snapshot = entries
        lock.unlock()
        guard write, let file, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func fingerprint(of bundle: URL) -> Fingerprint? {
        var root = stat()
        guard lstat(bundle.path, &root) == 0 else { return nil }
        let parts = ["", "/Contents", "/Contents/Info.plist", "/Contents/MacOS"]
        let times = parts.map { part -> Double in
            var status = stat()
            guard lstat(bundle.path + part, &status) == 0 else { return 0 }
            return Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1e9
        }
        return Fingerprint(device: Int64(root.st_dev), inode: UInt64(root.st_ino), times: times)
    }
}
