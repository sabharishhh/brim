import BrimCore
import BrimProtocol
import Combine
import Foundation

/// An install being recorded, shared by Home, the menu bar and the sheet
/// that shows what it found.
///
/// The first snapshot is kept by the service, so a recording outlives
/// Brim: reopening finds it still open and says since when.
@MainActor
public final class InstallRecordingModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case finishing(since: Date)
        case found(InstallRecordingResult)
    }

    @Published public private(set) var phase: Phase = .idle
    /// What went wrong last, shown once. A failure never ends a recording
    /// that is open: the first snapshot is still kept.
    @Published public var problem: String?
    private var service: (any BrimServiceProtocol)?
    private var hasLoaded = false

    public init() {}

    public var since: Date? {
        switch phase {
        case let .recording(since), let .finishing(since): since
        default: nil
        }
    }

    public var isRecording: Bool {
        since != nil
    }

    /// Picks up a recording left open when Brim last quit.
    public func load(service: any BrimServiceProtocol) async {
        self.service = service
        guard !hasLoaded else { return }
        hasLoaded = true
        if phase == .idle, let since = await service.activeInstallRecording() {
            phase = .recording(since: since)
        }
    }

    public func start(service: any BrimServiceProtocol) async {
        self.service = service
        guard phase == .idle else { return }
        phase = .starting
        do {
            phase = try await .recording(since: service.beginInstallRecording())
        } catch {
            phase = .idle
            problem = error.localizedDescription
        }
    }

    public func finish() async {
        guard let service, let since else { return }
        phase = .finishing(since: since)
        do {
            phase = try await .found(service.finishInstallRecording())
        } catch {
            phase = .recording(since: since)
            problem = error.localizedDescription
        }
    }

    /// Ends the recording without keeping anything.
    public func cancel() async {
        await service?.cancelInstallRecording()
        phase = .idle
    }

    /// Goes back to recording, for a result shown too early: the app was
    /// not opened yet, or its setup had not finished.
    public func keepRecording() {
        guard case let .found(result) = phase else { return }
        phase = .recording(since: result.startedAt)
    }

    /// Keeps the chosen apps and items. Returns whether it was saved.
    public func keep(_ result: InstallRecordingResult, apps: Set<String>, items: Set<String>) async -> Bool {
        guard let service else { return false }
        let chosenApps = result.apps.filter { apps.contains($0.id) }
        guard !chosenApps.isEmpty else { return false }
        let chosenItems = (result.linked + result.unclaimed).filter { item in
            items.contains(item.id) && (item.app == nil || apps.contains(item.app ?? ""))
        }
        let recording = InstallRecording(startedAt: result.startedAt, endedAt: result.endedAt, apps: chosenApps,
                                         items: chosenItems)
        do {
            try await service.keepInstallRecording(recording)
            phase = .idle
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }
}
