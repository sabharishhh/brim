import BrimCore
import BrimProtocol
import Combine
import Foundation
import os

/// One footprint group in a review: what moves, what the person may tick,
/// and what stays and why, in the inspector's order. The result reports each
/// group in the same order, so a file can be followed from evidence to
/// outcome.
public struct UninstallReviewGroup: Identifiable, Sendable {
    public let loss: FootprintLoss
    /// Steps the plan will carry out, in plan order.
    public let steps: [Step]
    /// Found, left unticked, and the person's to include.
    public let offers: [ExcludedItem]
    /// Kept out whatever is asked, with the reason: shared, protected, or
    /// only finishable by the person.
    public let staying: [ExcludedItem]

    public var id: String {
        loss.rawValue
    }

    public var title: String {
        loss.navigationTitle
    }

    public var isEmpty: Bool {
        steps.isEmpty && offers.isEmpty && staying.isEmpty
    }
}

/// Drives one uninstall: plan, a single approval, apply, then verify. The
/// check reports what it found rather than declaring success because the
/// commands ran.
@MainActor
public final class UninstallExecutionModel: ObservableObject {
    public enum Phase: Equatable {
        case preparing
        /// Planned and waiting for the user to authorize.
        case ready
        case executing
        /// Applied, and re-checked afterwards.
        case verified(VerificationResult)
        /// Applied, but the re-check itself could not run. Not `failed`: the removal
        /// went through, and the review must say which of the two happened.
        case appliedButUnverified(String)
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .preparing
    @Published public private(set) var plan: Plan?
    @Published public private(set) var reviewGroups: [UninstallReviewGroup] = []

    /// Rows the person ticked that Brim had left unticked. Sent on the intent,
    /// so each change is a new plan and approval covers exactly the one on
    /// screen.
    @Published public private(set) var tickedByHand: Set<String> = []

    /// A plan for the current ticks is being built. The plan on screen is the
    /// previous one until it arrives, so it cannot be approved meanwhile.
    @Published public private(set) var isUpdating = false

    private var service: (any BrimServiceProtocol)?
    /// The intent the sheet was opened with, before anything was ticked.
    private var baseIntent: PlanIntent?
    /// Which request for a plan is the latest; a reply to an older one answers a
    /// choice the person has since changed.
    private var generation = 0
    private var preparation = 0

    public init() {}

    public var isBusy: Bool {
        switch phase {
        case .preparing, .executing: true
        case .ready, .verified, .appliedButUnverified, .failed: false
        }
    }

    public var canAuthorize: Bool {
        guard case .ready = phase, let plan, !isUpdating else { return false }
        return !plan.steps.isEmpty
    }

    /// What Brim found and did not tick, which the person may. A vetoed row is
    /// not offered: the planner would not take it whatever the intent says.
    public var rowsToOffer: [ExcludedItem] {
        (plan?.excludedItems ?? []).filter { $0.canBeTickedByHand == true }
    }

    public func isTickedByHand(_ path: String) -> Bool {
        tickedByHand.contains(path)
    }

    /// Another group's pending plan does not disable this group's selection.
    public func canSelectAll(in group: UninstallReviewGroup) -> Bool {
        guard phase == .ready else { return false }
        return group.offers.contains { !tickedByHand.contains($0.target) }
    }

    /// Ticks or unticks one row and plans again. Only while the plan waits for
    /// approval.
    public func setTicked(_ ticked: Bool, path: String) async {
        await setTicked(ticked, paths: [path])
    }

    /// A subgroup changes in one request, rather than rescanning once per row.
    public func setTicked(_ ticked: Bool, paths: Set<String>) async {
        guard case .ready = phase else { return }
        let previous = tickedByHand
        if ticked {
            let offered = Set(rowsToOffer.map(\.target))
            tickedByHand.formUnion(paths.intersection(offered))
        } else {
            tickedByHand.subtract(paths)
        }
        guard previous != tickedByHand else { return }
        generation += 1
        await rebuild()
    }

    private func rebuild() async {
        guard let service, let baseIntent, !isUpdating else { return }
        let sheet = preparation
        isUpdating = true
        // Only one scan runs at a time. Changes made during it are combined
        // into one subsequent plan for the latest selection.
        while sheet == preparation {
            let asked = generation
            do {
                let planned = try await service.plan(intent: baseIntent.tickingByHand(tickedByHand))
                guard sheet == preparation else { return }
                guard asked == generation else { continue }
                plan = planned
                reviewGroups = Self.grouped(planned)
                isUpdating = false
                return
            } catch {
                guard sheet == preparation else { return }
                guard asked == generation else { continue }
                isUpdating = false
                phase = .failed(error.localizedDescription)
                return
            }
        }
    }

    /// Steps that remove something, without the bookkeeping ones, so "12
    /// locations" means twelve things on disk.
    private nonisolated static let bookkeepingKinds: Set<StepKind> = [
        .resetPrivacyGrants, .unloadLaunchdJob, .unregisterLaunchServices, .removeDockShortcut
    ]

    public var removalSteps: [Step] {
        (plan?.steps ?? []).filter { !Self.bookkeepingKinds.contains($0.kind) }
    }

    /// What the plan keeps and cannot be ticked, with the reason. Shown
    /// before approval so nothing is learned only from the result.
    public var staying: [ExcludedItem] {
        // Nil comes from an older plan and reads as not tickable.
        (plan?.excludedItems ?? []).filter { $0.canBeTickedByHand != true }
    }

    /// How many removals go through Brim's helper.
    public var helperSteps: Int {
        removalSteps.filter { $0.kind == .trashPathPrivileged }.count
    }

    /// The plan by footprint group, in display order, empty groups left out.
    /// Pure, so it can be worked out anywhere.
    nonisolated static func grouped(_ plan: Plan) -> [UninstallReviewGroup] {
        let shown = plan.steps.filter { !bookkeepingKinds.contains($0.kind) }
        let steps = Dictionary(grouping: shown, by: FootprintLoss.of)
        let rows = Dictionary(grouping: plan.excludedItems) { FootprintLoss.of(url: URL(fileURLWithPath: $0.target)) }
        return FootprintLoss.displayOrder.compactMap { loss in
            let excluded = rows[loss] ?? []
            let group = UninstallReviewGroup(
                loss: loss,
                steps: steps[loss] ?? [],
                offers: excluded.filter { $0.canBeTickedByHand == true },
                staying: excluded.filter { $0.canBeTickedByHand != true }
            )
            return group.isEmpty ? nil : group
        }
    }

    public func prepare(intent: PlanIntent, service: any BrimServiceProtocol) async {
        preparation += 1
        self.service = service
        baseIntent = intent
        tickedByHand = Set(intent.tickedByHand ?? [])
        // Anything still being built belongs to a review being set up again and
        // must not land on this one.
        generation += 1
        let asked = generation
        isUpdating = false
        plan = nil
        reviewGroups = []
        phase = .preparing
        let interval = BrimLog.signposter.beginInterval("Review plan")
        defer { BrimLog.signposter.endInterval("Review plan", interval) }
        do {
            let planned = try await service.plan(intent: intent)
            guard asked == generation else { return }
            plan = planned
            reviewGroups = Self.grouped(planned)
            phase = .ready
        } catch {
            guard asked == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Reviews a plan the service already made, as it is. A tool's own cleanup
    /// names a command rather than paths, so planning it again from its intent
    /// would review something else.
    public func adopt(plan adopted: Plan, service: any BrimServiceProtocol) {
        self.service = service
        baseIntent = adopted.intent
        tickedByHand = []
        generation += 1
        isUpdating = false
        plan = adopted
        reviewGroups = Self.grouped(adopted)
        phase = .ready
    }

    /// Why the disk did not give back what was deleted: a file whose blocks a
    /// local snapshot still holds frees nothing until the snapshot expires.
    public var spaceExplanation: String? {
        guard case let .verified(result) = phase, let plan,
              result.success, result.freeSpaceMeasured == true else { return nil }
        let promised = plan.immediatelyFreedBytes
        // Below this, other disk activity moves free space more than the removal
        // could.
        guard promised >= 100_000_000 else { return nil }

        // A tenth is slack for other disk activity during the removal.
        guard result.recoveredBytes < promised / 10 else { return nil }

        return "The files are gone, but free space barely changed. Snapshots, shared file blocks "
            + "or other activity on this Mac can account for it."
    }

    /// Called the moment a removal is verified, with the paths that went, so the
    /// list behind it can drop them without rescanning.
    public var onRemoved: (@MainActor (Set<String>) -> Void)?

    /// One authorization for the whole plan, then apply, then verify.
    public func authorize(requesterIdentity: String) async {
        // Not while a new plan is being built: the one on screen no longer
        // matches what the person has ticked.
        guard let service, let plan, case .ready = phase, !isUpdating else { return }

        phase = .executing
        do {
            try await service.approveAndApply(
                planId: plan.planId, requesterIdentity: requesterIdentity
            )
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // Applied; now verify. A failure to verify is reported, never swallowed.
        do {
            let result = try await service.verify(planId: plan.planId)
            phase = .verified(result)
            // Whatever the check proved gone, said straight away. What is
            // still there stays on screen, because it is still there.
            let planned = plan.steps.filter(\.kind.targetIsPath).map(\.target)
            onRemoved?(result.removedPaths(from: planned))
        } catch {
            phase = .appliedButUnverified(error.localizedDescription)
            // The removal ran and only the check failed, so the list learns nothing
            // about what went and refreshes on dismissal instead.
        }
    }
}
