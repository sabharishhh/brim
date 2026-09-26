import Foundation
import Combine
import BrimCore
import BrimProtocol

/// Drives one uninstall from plan to proof: plan, a single approval, apply,
/// and then verification.
///
/// Verification is not decoration. The product's claim is that after Brim
/// removes something, nothing is left — so the sheet re-checks and reports
/// what it found rather than declaring success because the commands ran.
@MainActor
public final class UninstallExecutionModel: ObservableObject {

    public enum Phase: Equatable {
        case preparing
        /// Planned and waiting for the user to authorize.
        case ready
        case executing
        /// Applied, and re-checked afterwards.
        case verified(VerificationResult)
        /// Applied, but the re-check itself could not run.
        ///
        /// Its own case because it used to share `failed`, which the sheet
        /// draws in red under the heading "Stopped". A person whose removal
        /// had in fact gone through, and whose verification pass then failed
        /// for its own reasons, was told the whole thing had been stopped.
        /// The removal is not undone by a failed check and the sheet has to
        /// say which of the two happened.
        case appliedButUnverified(String)
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .preparing
    @Published public private(set) var plan: Plan?

    /// Rows the person ticked in the sheet, which Brim had found and left
    /// unticked. Held here and sent on the intent, so every change of mind
    /// is a new plan and the approval covers exactly the one on screen.
    @Published public private(set) var tickedByHand: Set<String> = []

    /// A plan for the current ticks is being built. The plan on screen is the
    /// previous one until it arrives, so it cannot be approved meanwhile.
    @Published public private(set) var isUpdating = false

    private var service: (any BrimServiceProtocol)?
    /// The intent the sheet was opened with, before anything was ticked.
    private var baseIntent: PlanIntent?
    /// Which request for a plan is the latest. A reply for an older one is
    /// thrown away, because it answers a choice the person has since changed.
    private var generation = 0

    public init() {}

    public var isBusy: Bool {
        switch phase {
        case .preparing, .executing: return true
        case .ready, .verified, .appliedButUnverified, .failed: return false
        }
    }

    public var canAuthorize: Bool {
        guard case .ready = phase, let plan, !isUpdating else { return false }
        return !plan.steps.isEmpty
    }

    /// What Brim found and did not tick, which the person may.
    ///
    /// A vetoed row is not here. Something else on this Mac claims it, and
    /// the planner will not put it back whatever the intent says, so offering
    /// a box that does nothing would be a lie.
    public var rowsToOffer: [ExcludedItem] {
        (plan?.excludedItems ?? []).filter { $0.canBeTickedByHand == true }
    }

    public func isTickedByHand(_ path: String) -> Bool {
        tickedByHand.contains(path)
    }

    /// Tick or untick one row, and build the plan for the new choice.
    ///
    /// Only while the plan is waiting for approval. Once the removal has
    /// started, or finished, the plan is what it is.
    public func setTicked(_ ticked: Bool, path: String) async {
        guard case .ready = phase else { return }
        guard ticked != tickedByHand.contains(path),
              !ticked || rowsToOffer.contains(where: { $0.target == path }) else { return }
        if ticked { tickedByHand.insert(path) } else { tickedByHand.remove(path) }
        await rebuild()
    }

    private func rebuild() async {
        guard let service, let baseIntent else { return }
        generation += 1
        let asked = generation
        isUpdating = true
        do {
            let planned = try await service.plan(intent: baseIntent.tickingByHand(tickedByHand))
            guard asked == generation else { return }
            plan = planned
            isUpdating = false
        } catch {
            guard asked == generation else { return }
            isUpdating = false
            phase = .failed(error.localizedDescription)
        }
    }

    /// Steps that remove something, excluding the bookkeeping ones. Used for
    /// the counts the sheet shows, so "12 locations" means twelve things on
    /// disk rather than twelve plan entries.
    private static let bookkeepingKinds: Set<StepKind> = [
        .resetPrivacyGrants, .unloadLaunchdJob, .unregisterLaunchServices
    ]

    public var removalSteps: [Step] {
        (plan?.steps ?? []).filter { !Self.bookkeepingKinds.contains($0.kind) }
    }

    /// Whether this plan also retracts the app's Launch Services
    /// registration — the reason a removed app stops appearing in
    /// "Open With".
    public var clearsRegistrations: Bool {
        (plan?.steps ?? []).contains { $0.kind == .unregisterLaunchServices }
    }

    /// Whether this plan also clears the app's privacy permissions.
    public var clearsPrivacyGrants: Bool {
        (plan?.steps ?? []).contains { $0.kind == .resetPrivacyGrants }
    }

    public func prepare(intent: PlanIntent, service: any BrimServiceProtocol) async {
        self.service = service
        baseIntent = intent
        tickedByHand = Set(intent.tickedByHand ?? [])
        // Anything still being built belongs to a sheet that is being set up
        // again, and must not land on top of this one.
        generation += 1
        let asked = generation
        isUpdating = false
        plan = nil
        phase = .preparing
        do {
            let planned = try await service.plan(intent: intent)
            guard asked == generation else { return }
            plan = planned
            phase = .ready
        } catch {
            guard asked == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Why the disk did not give back what was deleted.
    ///
    /// Deleting a file whose blocks are still referenced by a local
    /// snapshot frees nothing until that snapshot expires. Reporting the
    /// removal as a success and leaving the user to notice that their free
    /// space never moved is how a cleaning tool loses trust, so this says
    /// it plainly instead.
    public var spaceExplanation: String? {
        guard case .verified(let result) = phase, let plan else { return nil }
        let promised = plan.immediatelyFreedBytes
        guard promised > 0 else { return nil }

        // A tenth is slack for other activity on the disk during the
        // removal, not a threshold worth tuning.
        guard result.recoveredBytes < promised / 10 else { return nil }

        return "The files are gone, but the disk has not given the space back yet. That "
             + "happens when a local snapshot still refers to the same blocks. macOS "
             + "releases them when the snapshot expires or when it needs the room."
    }

    /// Told the moment a removal is proved, with the paths that went.
    ///
    /// Not when the sheet is dismissed. The list behind it used to wait for
    /// Done and then rescan the whole Mac to discover what had changed,
    /// which it already knew, so a row the person had just watched be
    /// removed sat there for another four hundred milliseconds.
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

        // Applied. Now prove it: a failure to verify is reported, not
        // swallowed, because an unverified removal is the thing this product
        // exists to avoid.
        do {
            let result = try await service.verify(planId: plan.planId)
            phase = .verified(result)
            // Whatever the check proved gone, said straight away. What is
            // still there stays on screen, because it is still there.
            let planned = plan.steps.filter { $0.kind.targetIsPath }.map(\.target)
            onRemoved?(result.removedPaths(from: planned))
        } catch {
            phase = .appliedButUnverified(error.localizedDescription)
            // The removal ran and only the proof failed, so the list cannot
            // be told anything about what went. It refreshes on dismissal,
            // which is the one case where waiting is the honest answer.
        }
    }
}
