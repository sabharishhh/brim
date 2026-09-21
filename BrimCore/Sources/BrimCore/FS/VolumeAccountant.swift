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
    /// Local Time Machine snapshots on this volume. They are the usual
    /// reason a large deletion frees nothing until they expire.
    public let localSnapshots: Int
    public let isRemovable: Bool

    public var id: String { url.path }

    public var used: Int64 { max(0, capacity - freeRightNow - reclaimableByTheSystem) }

    /// What Finder reports, and why its number and ours differ.
    public var freeAsFinderReportsIt: Int64 { freeRightNow + reclaimableByTheSystem }

    public init(
        name: String, url: URL, capacity: Int64, freeRightNow: Int64,
        reclaimableByTheSystem: Int64, localSnapshots: Int, isRemovable: Bool
    ) {
        self.name = name
        self.url = url
        self.capacity = capacity
        self.freeRightNow = freeRightNow
        self.reclaimableByTheSystem = reclaimableByTheSystem
        self.localSnapshots = localSnapshots
        self.isRemovable = isRemovable
    }
}

/// Reads the space figures from the volumes themselves.
public struct VolumeAccountant: Sendable {

    /// Lists local snapshots on a volume. Injected so the accounting can be
    /// tested without a machine that happens to have them.
    private let snapshotCount: @Sendable (URL) -> Int

    public init(snapshotCount: (@Sendable (URL) -> Int)? = nil) {
        self.snapshotCount = snapshotCount ?? { Self.countLocalSnapshots(on: $0) }
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
                localSnapshots: snapshotCount(url),
                isRemovable: values.volumeIsRemovable ?? false
            )
        }
        .sorted { $0.capacity > $1.capacity }
    }

    /// `tmutil listlocalsnapshots` needs no privileges and is the supported
    /// way to ask. Counting rather than sizing is deliberate: sizing a
    /// snapshot needs `diskutil apfs`, which does want an administrator,
    /// and the space they hold is already inside the reclaimable figure.
    static func countLocalSnapshots(on volume: URL) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", volume.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").filter {
            $0.contains("com.apple.TimeMachine")
        }.count
    }
}
