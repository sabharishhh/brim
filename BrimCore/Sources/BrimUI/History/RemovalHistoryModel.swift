import BrimCore
import BrimProtocol
import Combine
import Foundation

/// One past removal, as History shows it.
public struct RemovalRecord: Identifiable, Equatable, Sendable {
    public let plan: Plan
    /// Present only while the removal can still be undone.
    public let recoverable: RecoverableItem?

    public var id: UUID {
        plan.planId
    }

    /// Removals from Remnants were recorded under its old name, Leftovers,
    /// and the Journal showed a page that no longer exists.
    public var name: String {
        let recorded = plan.intent.subjectIdentity.name
        return recorded == "Leftovers" ? "Remnants" : recorded
    }

    public var itemCount: Int {
        plan.steps.count
    }

    public var bytes: Int64 {
        plan.expectedTotalBytes
    }

    public var canUndo: Bool {
        recoverable != nil
    }

    /// Why undo is unavailable, in the user's terms, or nil when it is.
    public var unavailableReason: String? {
        Self.unavailableReason(plan: plan, recoverable: recoverable)
    }

    private static func unavailableReason(plan: Plan, recoverable: RecoverableItem?) -> String? {
        if recoverable != nil {
            return nil
        }
        if plan.steps.contains(where: { $0.kind == .trashPathPrivileged && $0.effectiveDisposition == .trash }) {
            return "Set aside. Brim cannot put this back."
        }
        if plan.steps.contains(where: { $0.kind == .delegateToolCleanup }) {
            return "Run by the tool. Cannot be undone."
        }
        return plan.isReversible ? "No longer in the Trash" : "Deleted permanently"
    }

    /// When it happened, written once.
    ///
    /// The row used to build this with `Text(date, format: .dateTime...)`,
    /// which constructs and applies a `Date.FormatStyle` every time the row
    /// is drawn. Date formatting is among the slowest things in Foundation,
    /// and thirty-nine rows doing it on every frame of a scroll is the
    /// whole reason this panel felt heavy. A record's date does not change.
    public let occurred: String

    public init(plan: Plan, recoverable: RecoverableItem?) {
        self.plan = plan
        self.recoverable = recoverable

        occurred = Self.dateStyle.format(plan.createdAt)
    }

    /// Built once for the whole process rather than per row. A
    /// `Date.FormatStyle` is cheap to reuse and expensive to construct.
    private static let dateStyle = Date.FormatStyle.dateTime
        .month().day().hour().minute()
}

/// Backs the History view: what was removed, and what can still be put back.
///
/// Recoverability is recomputed from the service rather than remembered, so
/// emptying the Trash is reflected here as immediately as it is in the queue.
@MainActor
public final class RemovalHistoryModel: ObservableObject {
    @Published public private(set) var records: [RemovalRecord] = []
    /// Every installation the snapshots record, for the Journal.
    @Published public private(set) var installs: [InstallRecord] = []
    @Published public private(set) var isLoading = false
    /// Why the removal history could not be read. Its own fact: a failed
    /// read used to leave the list empty, and the Journal said "Nothing yet".
    @Published public private(set) var loadError: String?
    @Published public private(set) var undoingPlanIds: Set<UUID> = []
    @Published public var errorMessage: String?
    /// What the last Put Back of each record did, shown beside that record.
    /// After a restore the record can no longer be undone, and without this
    /// its row read "No longer in the Trash", which is true and says nothing
    /// about the person's files having just come back.
    @Published public private(set) var putBackOutcomes: [UUID: PutBackOutcome] = [:]

    public enum PutBackOutcome: Equatable, Sendable {
        case restored
        case failed(String)
    }

    /// Removals whose items are being deleted from the Trash.
    @Published public private(set) var deletingPlanIds: Set<UUID> = []
    /// Each confirmed removal looked at again, by plan. Empty until the
    /// Journal asks, and never saved.
    @Published public private(set) var rechecks: [UUID: RemovalRecheck.State] = [:]

    /// How many confirmed removals have files on the disk again.
    public var cameBackCount: Int {
        rechecks.values.filter {
            if case .cameBack = $0 {
                return true
            }
            return false
        }.count
    }

    /// Everything before this is cleared from the Journal, except removals
    /// that can still be put back: hiding one of those would hide the only
    /// way back to the person's files.
    @Published public private(set) var clearedBefore: Date?

    private var service: (any BrimServiceProtocol)?
    private let defaults: UserDefaults
    private static let clearedKey = "journal.clearedBefore"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.clearedKey)
        clearedBefore = stored > 0 ? Date(timeIntervalSinceReferenceDate: stored) : nil
    }

    /// The removals the Journal lists.
    public var visibleRecords: [RemovalRecord] {
        guard let clearedBefore else { return records }
        return records.filter { $0.canUndo || $0.plan.createdAt > clearedBefore }
    }

    /// The installs the Journal lists.
    public var visibleInstalls: [InstallRecord] {
        guard let clearedBefore else { return installs }
        return installs.filter { $0.installedAt > clearedBefore }
    }

    /// What Brim's removals still hold in the Trash. None of it comes back
    /// to the disk until the Trash is emptied, which is why Space shows it
    /// apart from everything else.
    public var bytesInTrash: Int64 {
        records.reduce(0) { $0 + ($1.recoverable?.bytes ?? 0) }
    }

    /// Whether clearing would take anything out of the Journal.
    public var canClear: Bool {
        visibleRecords.contains { !$0.canUndo } || !visibleInstalls.isEmpty
    }

    /// Clears the Journal up to now. Brim keeps its removal records, which
    /// later checks of a removal read; they are no longer listed.
    public func clear(now: Date = Date()) {
        clearedBefore = now
        defaults.set(now.timeIntervalSinceReferenceDate, forKey: Self.clearedKey)
    }

    public func load(service: any BrimServiceProtocol) async {
        self.service = service
        isLoading = records.isEmpty
        defer { isLoading = false }
        await reload()
    }

    /// Looks again at every confirmed removal. `installed` is the
    /// identifiers on the Mac now, so a reinstall reads as one.
    public func recheck(installed: Set<String>) async {
        guard let service else { return }
        let found = await service.recheckRemovals(installed: installed)
        rechecks = Dictionary(found.map { ($0.planId, $0.state) }, uniquingKeysWith: { _, latest in latest })
    }

    /// Recompute from the service. Cheap enough to call on every Trash change.
    public func reload() async {
        guard let service else { return }

        async let recoverableTask = try? await service.recoverableItems()
        async let installsTask = service.installRecords()
        let plans: [Plan]
        do {
            plans = try await service.history()
            loadError = nil
        } catch {
            // What was read before is still what is known; it is not
            // replaced by an empty list that claims there is nothing.
            loadError = error.localizedDescription
            plans = records.map(\.plan)
        }
        let recoverable = await recoverableTask ?? []
        installs = await installsTask

        let byPlan = Dictionary(uniqueKeysWithValues: recoverable.map { ($0.planId, $0) })
        records = plans
            .map { RemovalRecord(plan: $0, recoverable: byPlan[$0.planId]) }
            .sorted { $0.plan.createdAt > $1.plan.createdAt }
    }

    /// Deletes for good what these removals put in the Trash. Nothing else
    /// in the Trash is touched.
    public func deleteFromTrash(_ records: [RemovalRecord]) async {
        guard let service else { return }
        let ids = Set(records.map(\.id)).subtracting(deletingPlanIds)
        guard !ids.isEmpty else { return }
        deletingPlanIds.formUnion(ids)
        defer { deletingPlanIds.subtract(ids) }
        errorMessage = nil
        var failures: [String] = []
        for record in records where ids.contains(record.id) {
            do {
                try await service.deleteFromTrash(planId: record.plan.planId)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
        await reload()
    }

    /// Restores one removal. The service refuses cleanly when it cannot, and
    /// that sentence is what the user sees.
    public func undo(_ record: RemovalRecord) async {
        guard let service, !undoingPlanIds.contains(record.id) else { return }

        undoingPlanIds.insert(record.id)
        defer { undoingPlanIds.remove(record.id) }
        errorMessage = nil
        putBackOutcomes[record.id] = nil

        do {
            try await service.undo(planId: record.plan.planId)
            putBackOutcomes[record.id] = .restored
        } catch {
            errorMessage = error.localizedDescription
            putBackOutcomes[record.id] = .failed(error.localizedDescription)
        }

        // Reload either way: a failed undo usually means the world moved, and
        // the list should show the new truth rather than what we assumed.
        await reload()
    }
}
