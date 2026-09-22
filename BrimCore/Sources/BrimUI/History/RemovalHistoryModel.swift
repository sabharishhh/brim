import Foundation
import Combine
import BrimCore
import BrimProtocol

/// One past removal, as History shows it.
public struct RemovalRecord: Identifiable, Equatable, Sendable {
    public let plan: Plan
    /// Present only while the removal can still be undone.
    public let recoverable: RecoverableItem?

    public var id: UUID { plan.planId }
    public var name: String { plan.intent.subjectIdentity.name }
    public var itemCount: Int { plan.steps.count }
    public var bytes: Int64 { plan.expectedTotalBytes }
    public var canUndo: Bool { recoverable != nil }

    /// Why undo is unavailable, in the user's terms — nil when it is.
    public var unavailableReason: String? {
        if recoverable != nil { return nil }
        return plan.isReversible
            ? "No longer in the Trash"
            : "Deleted permanently"
    }

    /// When it happened, written once.
    ///
    /// The row used to build this with `Text(date, format: .dateTime...)`,
    /// which constructs and applies a `Date.FormatStyle` every time the row
    /// is drawn. Date formatting is among the slowest things in Foundation,
    /// and thirty-nine rows doing it on every frame of a scroll is the
    /// whole reason this panel felt heavy. A record's date does not change.
    public let occurred: String

    /// What a screen reader says, also written once, for the same reason:
    /// the row was assembling this string on every pass.
    public let spoken: String

    public init(plan: Plan, recoverable: RecoverableItem?) {
        self.plan = plan
        self.recoverable = recoverable

        self.occurred = Self.dateStyle.format(plan.createdAt)

        // Moved here verbatim from the view, which was assembling it on
        // every pass. The wording is not incidental: gluing the reason on
        // with `?? ""` once read out as "Figma, 3 items, 40 MB. , cannot be
        // undone", and saying "items" for a removal of one disagreed with
        // the row beside it.
        let count = plan.steps.count
        let items = "\(count) \(count == 1 ? "item" : "items")"
        var parts = [
            "\(plan.intent.subjectIdentity.name), \(items), "
            + ByteText.short(plan.expectedTotalBytes)
        ]
        let reason = recoverable != nil
            ? nil
            : (plan.isReversible ? "No longer in the Trash" : "Deleted permanently")
        if recoverable != nil {
            parts.append("Can be undone")
        } else if let reason, !reason.isEmpty {
            parts.append("\(reason), so it cannot be undone")
        } else {
            parts.append("Cannot be undone")
        }
        self.spoken = parts.joined(separator: ". ") + "."
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
    @Published public private(set) var isLoading = false
    @Published public private(set) var undoingPlanIds: Set<UUID> = []
    @Published public var errorMessage: String?

    private var service: (any BrimServiceProtocol)?

    public init() {}

    public func load(service: any BrimServiceProtocol) async {
        self.service = service
        isLoading = records.isEmpty
        defer { isLoading = false }
        await reload()
    }

    /// Recompute from the service. Cheap enough to call on every Trash change.
    public func reload() async {
        guard let service else { return }

        async let plansTask = try? await service.history()
        async let recoverableTask = try? await service.recoverableItems()
        let plans = await plansTask ?? []
        let recoverable = await recoverableTask ?? []

        let byPlan = Dictionary(uniqueKeysWithValues: recoverable.map { ($0.planId, $0) })
        records = plans
            .map { RemovalRecord(plan: $0, recoverable: byPlan[$0.planId]) }
            .sorted { $0.plan.createdAt > $1.plan.createdAt }
    }

    /// Restores one removal. The service refuses cleanly when it cannot, and
    /// that sentence is what the user sees.
    public func undo(_ record: RemovalRecord) async {
        guard let service, !undoingPlanIds.contains(record.id) else { return }

        undoingPlanIds.insert(record.id)
        defer { undoingPlanIds.remove(record.id) }
        errorMessage = nil

        do {
            try await service.undo(planId: record.plan.planId)
        } catch {
            errorMessage = error.localizedDescription
        }

        // Reload either way: a failed undo usually means the world moved, and
        // the list should show the new truth rather than what we assumed.
        await reload()
    }
}
