import BrimCore
import Foundation

/// Cheap inventory metadata invalidates previews when an installed copy or
/// its bundle metadata changes. It never substitutes for execution readback.
struct RemovalInputStamp: Equatable, Sendable {
    let records: [String]
    let completeness: ScanCompleteness

    @concurrent
    static func read(in root: FileSystemRoot) async -> Self {
        let inventory = InstalledBundleInventory.read(in: root)
        let records = inventory.bundles.map { bundle in
            let code = ApplicationBundle.codeLocation(of: bundle)
            let paths = [bundle, bundle.appendingPathComponent("Contents/Info.plist"),
                         code.appendingPathComponent("Info.plist")]
            return paths.enumerated().map { index, url in
                var info = stat()
                guard lstat(url.path, &info) == 0 else { return "\(url.path):\(errno)" }
                let identity = "\(url.path):\(info.st_dev):\(info.st_ino)"
                // macOS changes bundle dates when opening an app. Its identity
                // and Info.plist matter here; an ordinary launch does not.
                guard index > 0 else { return identity }
                return identity + ":\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
            }.joined(separator: "|")
        }
        return Self(records: records, completeness: inventory.completeness)
    }
}

extension BrimService {
    func refreshRemovalPreviewInputs() async {
        if let invalidation = removalInvalidation {
            await invalidation.value
        }
        guard let current = try? await removalInputReads.value(for: true, load: {
            await RemovalInputStamp.read(in: self.root)
        }) else { return }
        let changed = removalInputStamp.map { $0 != current } ?? false
        removalInputStamp = current
        if changed {
            await invalidateRemovalPreviews()
        }
        if let invalidation = removalInvalidation {
            await invalidation.value
        }
    }
}
