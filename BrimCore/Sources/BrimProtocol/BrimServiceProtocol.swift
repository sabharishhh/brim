import BrimCore
import Foundation

/// The single API, behind which everything hides.
/// All parameters and returns are value types, ready to cross a process boundary in M2.
public protocol BrimServiceProtocol: Sendable {
    func inspect(identity: Identity) async throws -> Footprint
    func plan(intent: PlanIntent) async throws -> Plan
    func explain(planId: UUID) async throws -> String
    /// Asks for a person's approval. Returns an acknowledgement, never
    /// permission: there is deliberately no method here that produces an
    /// `ApprovalToken`. The answer comes back through `ApprovalGranting`,
    /// which only Brim's own process implements.
    func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt
    func apply(planId: UUID, token: ApprovalToken) async throws
    func verify(planId: UUID) async throws -> VerificationResult
    /// Re-observe a bounded set of unfinished removals once when the app opens.
    /// This never repeats an execution or obtains approval.
    func recheckPendingRemovals() async
    /// Looks again, by path only, at recent removals that were confirmed,
    /// and says whether what they took is still gone. `installed` is the
    /// identifiers of the applications on the Mac now, so a reinstall is
    /// recognised rather than reported as files coming back.
    func recheckRemovals(installed: Set<String>) async -> [RemovalRecheck]
    func history() async throws -> [Plan]
    func undo(planId: UUID) async throws
    /// Deletes for good what one removal put in the Trash, leaving the rest
    /// of the Trash alone. The removal can no longer be put back.
    func deleteFromTrash(planId: UUID) async throws
    /// Applications installed on this machine, for the Applications view.
    func installedApplications() async throws -> [InstalledApplication]
    func leftovers() async throws -> [Leftover]
    /// Past removals whose contents are still in the Trash, so still restorable.
    func recoverableItems() async throws -> [RecoverableItem]
    /// Clears registrations that became stale since the last look — chiefly
    /// when the user empties the Trash. Cheap, idempotent, and safe to call
    /// on every Trash change.
    func reconcileRegistrations() async
    /// Whether the owner has completed first-run setup.
    func isEnrolled() async -> Bool
    /// First-run setup: one confirmation that this Mac belongs to the person
    /// using it. Never asked again.
    func enroll() async throws
    /// Everything macOS has registered on behalf of software: launchd
    /// jobs, and the login items and background services in Background
    /// Task Management.
    ///
    /// This used to take a flag, because background items came from
    /// `sfltool` and reading them cost an administrator prompt. They are
    /// read from the store directly now, so there is nothing left to opt
    /// into and no reason to withhold half the answer.
    func registrations() async -> RegistrationReport
    /// Space on each local volume, kept as separate figures rather than
    /// collapsed into one.
    func volumes() async -> [VolumeAccount]
    /// A single sample of what is running and what it is costing.
    func sampleEnergy() async -> EnergySampleResult
    /// Build caches this Mac has accumulated, with what clearing each costs.
    func developerCaches() async -> [DeveloperCache]
    /// Snapshots from an on-demand scan. Rows keep their path identity while
    /// their measurements finish. Dropping the stream cancels its producer.
    func developerCacheUpdates(excluding folders: [URL]) async -> AsyncStream<[DeveloperCache]>
    /// Plans a tool's own cleanup, named rather than described. The command
    /// is resolved inside the service from a fixed table.
    func planToolCleanup(id: String, displayed: String) async throws -> Plan
    func planToolCleanup(id: String, cachePath: URL) async throws -> Plan
    func planHomebrewDownloads(cachePath: URL, excluding folders: [URL]) async throws -> Plan
    /// Hands the service a way to remove something in a folder that
    /// belongs to root, once Brim's privileged daemon is set up.
    func usePrivilegedRemover(_ remover: (@Sendable (String) async -> String?)?) async
    /// Hands the service a way to forget an installer receipt. Receipts
    /// live in a folder that belongs to root, so without the daemon the
    /// step records that the record remains rather than half succeeding.
    func usePrivilegedReceiptForgetter(_ forgetter: (@Sendable (String) async -> String?)?) async
    /// Starts protected work after approval and stops it on every exit path.
    func usePrivilegedBatch(begin: (@Sendable () async -> String?)?,
                            end: (@Sendable () async -> Void)?) async
    func useRecoveryVerifier(_ reader: (@Sendable () async throws -> [RecoveryCopy])?) async
    func useRecoveryCopies(reader: (@Sendable () async throws -> [RecoveryCopy])?,
                           remover: (@Sendable (String, TargetFingerprint) async -> String?)?) async
    /// What has been installed, removed or updated since Brim last
    /// looked, worked out by subtracting one snapshot from the one
    /// before it. Nothing watches, and nothing runs at login.
    func whatChanged() async -> InstallHistory
    /// Every installation Brim's snapshots record, removed apps included.
    func installRecords() async -> [InstallRecord]
    /// Checks every application for a newer version. Reaches the network.
    func checkForUpdates() async -> UpdateCheck
    /// Puts one update in place, reporting download progress from 0 to 1.
    func installUpdate(_ update: AppUpdate, progress: @escaping DownloadProgress.Handler) async -> UpdateOutcome
    /// What a package, disk image or uninstalled app would put on this Mac,
    /// read without installing it.
    func previewInstaller(at url: URL) async throws -> InstallerPreview
    /// Copies an app the person looked inside into Applications, after
    /// checking it is still the app the preview showed. Returns where it is.
    func installApplication(from source: URL, identifier: String?, trusted: Bool) async throws -> URL
    /// Takes the first snapshot of an install recording and keeps it, so
    /// the recording survives Brim quitting. Returns when it was taken.
    func beginInstallRecording() async throws -> Date
    /// When the recording under way began, if one is.
    func activeInstallRecording() async -> Date?
    func cancelInstallRecording() async
    /// The second snapshot, subtracted and attributed. Keeps nothing.
    func finishInstallRecording() async throws -> InstallRecordingResult
    /// Keeps what the person chose and ends the recording.
    func keepInstallRecording(_ recording: InstallRecording) async throws
    func installRecordings() async -> [InstallRecording]
}

public extension BrimServiceProtocol {
    func recheckPendingRemovals() async {}

    /// A service with no journal has no removals to look at again.
    func recheckRemovals(installed _: Set<String>) async -> [RemovalRecheck] {
        []
    }

    /// Ask, wait for the answer, then act on it.
    ///
    /// The one route from a plan to a removal, so there is one place where
    /// the gate is enforced rather than one per caller. A service that
    /// cannot ask a person does not conform to `ApprovalGranting`, and this
    /// stops before anything is touched.
    func approveAndApply(planId: UUID, requesterIdentity: String) async throws {
        let receipt = try await requestApproval(
            planId: planId, requesterIdentity: requesterIdentity
        )
        guard let granting = self as? ApprovalGranting else {
            throw ApprovalError.noHumanToAsk
        }
        let token = try await granting.grantApproval(for: receipt)
        try await apply(planId: planId, token: token)
    }

    /// Nothing to reconcile by default, so a service that does not track
    /// registrations — a test stub, or the XPC client until the daemon
    /// carries this — is not forced to implement it.
    func reconcileRegistrations() async {}

    /// A service that does not track enrolment is already past it, so
    /// nothing prompts. Keeps stubs and the XPC client conforming.
    func isEnrolled() async -> Bool {
        true
    }

    func enroll() async throws {}
    func registrations() async -> RegistrationReport {
        .empty
    }

    func volumes() async -> [VolumeAccount] {
        []
    }

    func sampleEnergy() async -> EnergySampleResult {
        EnergySampleResult(samples: [], coverageGaps: 0)
    }

    func developerCaches() async -> [DeveloperCache] {
        []
    }

    func developerCacheUpdates(excluding folders: [URL]) async -> AsyncStream<[DeveloperCache]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                let caches = await developerCaches()
                if !Task.isCancelled {
                    continuation.yield(caches.filter { cache in
                        !folders.contains { ArtifactSizer.rootsOverlap(cache.url, $0) }
                    })
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func planToolCleanup(id _: String, displayed _: String) async throws -> Plan {
        throw NSError(domain: "BrimService", code: 501,
                      userInfo: [NSLocalizedDescriptionKey: "Not supported here."])
    }

    func planToolCleanup(id _: String, cachePath _: URL) async throws -> Plan {
        throw NSError(domain: "BrimService", code: 501,
                      userInfo: [NSLocalizedDescriptionKey: "Scoped tool cleanup is not supported here."])
    }

    func planHomebrewDownloads(cachePath _: URL, excluding _: [URL]) async throws -> Plan {
        throw NSError(domain: "BrimService", code: 501,
                      userInfo: [NSLocalizedDescriptionKey: "Download cleanup is not supported here."])
    }

    /// A service with no executor of its own has nothing to hand it to.
    func usePrivilegedRemover(_: (@Sendable (String) async -> String?)?) async {}
    func usePrivilegedReceiptForgetter(_: (@Sendable (String) async -> String?)?) async {}
    func usePrivilegedBatch(begin _: (@Sendable () async -> String?)?,
                            end _: (@Sendable () async -> Void)?) async {}
    func useRecoveryVerifier(_: (@Sendable () async throws -> [RecoveryCopy])?) async {}
    func useRecoveryCopies(reader _: (@Sendable () async throws -> [RecoveryCopy])?,
                           remover _: (@Sendable (String, TargetFingerprint) async -> String?)?) async {}
    /// A service with no history has seen nothing change.
    func whatChanged() async -> InstallHistory {
        InstallHistory(changes: [], snapshots: 0)
    }

    func checkForUpdates() async -> UpdateCheck {
        UpdateCheck(updates: [], checked: 0, unchecked: [], checkedAt: Date())
    }

    func installUpdate(_: AppUpdate, progress _: @escaping DownloadProgress.Handler) async -> UpdateOutcome {
        .failed("Not supported here.")
    }

    func installRecords() async -> [InstallRecord] {
        []
    }

    func previewInstaller(at _: URL) async throws -> InstallerPreview {
        throw NSError(domain: "BrimService", code: 501,
                      userInfo: [NSLocalizedDescriptionKey: "Not supported here."])
    }

    func installApplication(from _: URL, identifier _: String?, trusted _: Bool) async throws -> URL {
        throw NSError(domain: "BrimService", code: 501,
                      userInfo: [NSLocalizedDescriptionKey: "Not supported here."])
    }

    func beginInstallRecording() async throws -> Date {
        throw NSError(domain: "BrimService", code: 501,
                      userInfo: [NSLocalizedDescriptionKey: "Not supported here."])
    }

    func activeInstallRecording() async -> Date? {
        nil
    }

    func cancelInstallRecording() async {}

    func finishInstallRecording() async throws -> InstallRecordingResult {
        throw NSError(domain: "BrimService", code: 501,
                      userInfo: [NSLocalizedDescriptionKey: "Not supported here."])
    }

    func keepInstallRecording(_: InstallRecording) async throws {
        throw NSError(domain: "BrimService", code: 501,
                      userInfo: [NSLocalizedDescriptionKey: "Not supported here."])
    }

    func installRecordings() async -> [InstallRecording] {
        []
    }

    func deleteFromTrash(planId _: UUID) async throws {
        throw NSError(domain: "BrimService", code: 501,
                      userInfo: [NSLocalizedDescriptionKey: "Not supported here."])
    }
}
