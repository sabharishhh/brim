import Foundation

/// What a volume's space is actually doing.
///
/// Disk space on an APFS volume is not one number, and every utility that
/// pretends otherwise ends up lying to somebody. "Free space" in Finder
/// already counts space macOS would reclaim under pressure, which is why
/// deleting a large file can leave the figure unchanged and why a cleaner
/// can claim to have freed gigabytes that never appear.
///
/// So this keeps them apart and names each one:
///
/// - **used** and **capacity**, the plain facts.
/// - **freeRightNow**, space genuinely unoccupied this second.
/// - **reclaimableByTheSystem**, space macOS is holding in caches and local
///   snapshots and will give back when something needs it. Real, but not
///   yours to plan with, and not something deleting files adds to.
///
/// Finder's headline figure is `freeRightNow + reclaimableByTheSystem`.
public struct VolumeAccount: Sendable, Equatable, Identifiable {
    public let name: String
    public let url: URL
    public let capacity: Int64
    public let freeRightNow: Int64
    public let reclaimableByTheSystem: Int64
    /// Local snapshots on this volume, and whether macOS considers each one
    /// disposable. They are the usual reason a large deletion frees nothing
    /// until they expire.
    public let snapshots: [VolumeSnapshot]
    public let isRemovable: Bool

    public var id: String { url.path }

    public var used: Int64 { max(0, capacity - freeRightNow - reclaimableByTheSystem) }

    /// Snapshots macOS will not discard on its own. These set a floor under
    /// the volume, and are why deleting a large file can free nothing.
    public var pinningSnapshots: [VolumeSnapshot] { snapshots.filter { !$0.isPurgeable } }

    /// What Finder reports, and why its number and ours differ.
    public var freeAsFinderReportsIt: Int64 { freeRightNow + reclaimableByTheSystem }

    public init(
        name: String, url: URL, capacity: Int64, freeRightNow: Int64,
        reclaimableByTheSystem: Int64, snapshots: [VolumeSnapshot], isRemovable: Bool
    ) {
        self.name = name
        self.url = url
        self.capacity = capacity
        self.freeRightNow = freeRightNow
        self.reclaimableByTheSystem = reclaimableByTheSystem
        self.snapshots = snapshots
        self.isRemovable = isRemovable
    }
}

/// One local snapshot.
///
/// Deliberately carries no size. macOS exposes no supported way to ask how
/// many bytes a snapshot is holding: `tmutil` lists names, `diskutil apfs
/// listSnapshots` adds whether each is purgeable, and neither reports a
/// figure. Inventing one would be worse than admitting it, so the view says
/// what is known and says what is not.
public struct VolumeSnapshot: Sendable, Equatable, Identifiable {
    public let name: String
    /// Whether macOS will discard it when it needs the room.
    public let isPurgeable: Bool

    public var id: String { name }

    public init(name: String, isPurgeable: Bool) {
        self.name = name
        self.isPurgeable = isPurgeable
    }
}

/// Reads the space figures from the volumes themselves.
public struct VolumeAccountant: Sendable {

    /// Lists local snapshots on a volume. Injected so the accounting can be
    /// tested without a machine that happens to have them.
    private let snapshots: @Sendable (URL) -> [VolumeSnapshot]

    public init(snapshots: (@Sendable (URL) -> [VolumeSnapshot])? = nil) {
        self.snapshots = snapshots ?? { Self.localSnapshots(on: $0) }
    }

    public func accounts() async -> [VolumeAccount] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRemovableKey, .volumeIsBrowsableKey, .volumeIsLocalKey
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  values.volumeIsLocal == true,
                  let capacity = values.volumeTotalCapacity
            else { return nil }

            let free = Int64(values.volumeAvailableCapacity ?? 0)
            // This one counts space macOS would reclaim under pressure, so
            // the difference between the two is what it is holding back.
            let important = values.volumeAvailableCapacityForImportantUsage ?? 0
            let reclaimable = max(0, important - free)

            return VolumeAccount(
                name: values.volumeName ?? url.lastPathComponent,
                url: url,
                capacity: Int64(capacity),
                freeRightNow: free,
                reclaimableByTheSystem: reclaimable,
                snapshots: snapshots(url),
                isRemovable: values.volumeIsRemovable ?? false
            )
        }
        .sorted { $0.capacity > $1.capacity }
    }

    /// Reads snapshots through `diskutil apfs listSnapshots`, which needs no
    /// privileges and reports whether each one is purgeable. `tmutil
    /// listlocalsnapshots` gives only names.
    static func localSnapshots(on volume: URL) -> [VolumeSnapshot] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "listSnapshots", volume.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseSnapshots(String(data: data, encoding: .utf8) ?? "")
    }

    /// Pulls name and purgeability out of the listing. Each snapshot is a
    /// block of indented `Key: value` lines under its identifier.
    static func parseSnapshots(_ text: String) -> [VolumeSnapshot] {
        var found: [VolumeSnapshot] = []
        var name: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = trimmed.dropPrefix("Name:") {
                // A new block begins. Anything pending had no purgeability
                // line, which means it was not reported as disposable.
                if let pending = name { found.append(VolumeSnapshot(name: pending, isPurgeable: false)) }
                name = value
            } else if let value = trimmed.dropPrefix("Purgeable:"), let pending = name {
                found.append(VolumeSnapshot(name: pending, isPurgeable: value.lowercased() == "yes"))
                name = nil
            }
        }
        if let pending = name { found.append(VolumeSnapshot(name: pending, isPurgeable: false)) }
        return found
    }
}

private extension String {
    /// The value after a `Key:` prefix, or nil when the line is something
    /// else.
    func dropPrefix(_ key: String) -> String? {
        guard hasPrefix(key) else { return nil }
        return String(dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
    }
}
