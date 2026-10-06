import BrimCore
import BrimProtocol
import BrimScan
import Foundation

public extension BrimService {
    func beginInstallRecording() async throws -> Date {
        let reader = InstallSnapshotReader(root: root, own: InstallSnapshotReader.ownNames(of: brimBundle))
        let snapshot = await Task.detached(priority: .userInitiated) { reader.take() }.value
        try await recordingStore.saveActive(snapshot)
        return snapshot.takenAt
    }

    func activeInstallRecording() async -> Date? {
        await recordingStore.active()?.takenAt
    }

    func cancelInstallRecording() async {
        await recordingStore.clearActive()
    }

    /// Takes the second snapshot and attributes what is new. Nothing is
    /// kept until the person says so, and the recording stays open until
    /// then, so quitting here loses nothing.
    func finishInstallRecording() async throws -> InstallRecordingResult {
        guard let before = await recordingStore.active() else { throw RecordingError.notRecording }
        let reader = InstallSnapshotReader(root: root, own: InstallSnapshotReader.ownNames(of: brimBundle))
        let after = await Task.detached(priority: .userInitiated) { reader.take() }.value
        let installed = await applicationInventoryRead().value.map { app in
            InstallClaimant(name: app.name, bundleID: app.identity.bundleID, names: app.identity.searchNames)
        }
        return InstallRecordingDiff.result(before: before, after: after, installed: installed)
    }

    func keepInstallRecording(_ recording: InstallRecording) async throws {
        try await recordingStore.keep(recording)
        await recordingStore.clearActive()
    }

    func installRecordings() async -> [InstallRecording] {
        await recordingStore.recordings()
    }

    /// Recorded items of apps that have gone, for Remnants.
    internal func recordedRemnants(listed: Set<String>) async -> [Leftover] {
        let recordings = await recordingStore.recordings()
        guard !recordings.isEmpty else { return [] }
        let installed = Set(InstalledBundleInventory.read(in: root).bundles.compactMap { url in
            (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"]
                as? String)?.lowercased()
        })
        return InstallRecordingSource.remnants(
            recordings, installed: installed, listed: listed,
            inUseWithin: root.rootURL.path == "/" ? 7 * 24 * 60 * 60 : nil
        )
    }

    enum RecordingError: LocalizedError {
        case notRecording

        public var errorDescription: String? {
            "No install is being recorded."
        }
    }
}
