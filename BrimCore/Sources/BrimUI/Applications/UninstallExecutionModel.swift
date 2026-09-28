import BrimCore
import BrimProtocol
import Combine
import Foundation

public struct UninstallReviewGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let steps: [Step]
}

public struct UninstallOfferGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let rows: [ExcludedItem]
}

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
    @Published public private(set) var reviewGroups: [UninstallReviewGroup] = []
    @Published public private(set) var offerGroups: [UninstallOfferGroup] = []

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
        if ticked {
            tickedByHand.insert(path)
        } else {
            tickedByHand.remove(path)
        }
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
                reviewGroups = Self.groupedSteps(planned.steps)
                offerGroups = Self.groupedOffers(planned.excludedItems)
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

    /// Steps that remove something, excluding the bookkeeping ones. Used for
    /// the counts the sheet shows, so "12 locations" means twelve things on
    /// disk rather than twelve plan entries.
    private static let bookkeepingKinds: Set<StepKind> = [
        .resetPrivacyGrants, .unloadLaunchdJob, .unregisterLaunchServices
    ]

    public var removalSteps: [Step] {
        (plan?.steps ?? []).filter { !Self.bookkeepingKinds.contains($0.kind) }
    }

    /// What the plan keeps and cannot be ticked, with the reason. Shown
    /// before approval so nothing is learned only from the result.
    public var staying: [ExcludedItem] {
        (plan?.excludedItems ?? []).filter { $0.canBeTickedByHand == false }
    }

    /// How many removals go through Brim's helper.
    public var helperSteps: Int {
        removalSteps.filter { $0.kind == .trashPathPrivileged }.count
    }

    private static func groupedSteps(_ steps: [Step]) -> [UninstallReviewGroup] {
        var order: [String] = []
        var buckets: [String: [Step]] = [:]
        for step in steps where !bookkeepingKinds.contains(step.kind) {
            let title = groupTitle(for: step.target, kind: step.kind)
            if buckets[title] == nil {
                order.append(title)
            }
            buckets[title, default: []].append(step)
        }
        if let app = order.firstIndex(of: "Application") {
            order.remove(at: app)
            order.insert("Application", at: 0)
        }
        return order.compactMap { title in
            guard let steps = buckets[title] else { return nil }
            return UninstallReviewGroup(id: title, title: title, steps: steps)
        }
    }

    private static func groupedOffers(_ rows: [ExcludedItem]) -> [UninstallOfferGroup] {
        var order: [String] = []
        var buckets: [String: [ExcludedItem]] = [:]
        for row in rows where row.canBeTickedByHand == true {
            let title = groupTitle(for: row.target, kind: nil)
            if buckets[title] == nil {
                order.append(title)
            }
            buckets[title, default: []].append(row)
        }
        return order.compactMap { title in
            guard let rows = buckets[title] else { return nil }
            return UninstallOfferGroup(id: title, title: title, rows: rows)
        }
    }

    private static func groupTitle(for target: String, kind: StepKind?) -> String {
        switch kind {
        case .forgetReceipt: return "Installer records"
        case .revealVendorUninstaller: return "Vendor uninstallers"
        default: break
        }
        let url = URL(fileURLWithPath: target)
        if url.pathExtension == "app" {
            return "Application"
        }
        let domain = LeftoverDomain.of(url)
        return domain == .other ? "Other files" : domain.title
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
        preparation += 1
        self.service = service
        baseIntent = intent
        tickedByHand = Set(intent.tickedByHand ?? [])
        // Anything still being built belongs to a sheet that is being set up
        // again, and must not land on top of this one.
        generation += 1
        let asked = generation
        isUpdating = false
        plan = nil
        reviewGroups = []
        offerGroups = []
        phase = .preparing
        do {
            let planned = try await service.plan(intent: intent)
            guard asked == generation else { return }
            plan = planned
            reviewGroups = Self.groupedSteps(planned.steps)
            offerGroups = Self.groupedOffers(planned.excludedItems)
            phase = .ready
        } catch {
            guard asked == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Reviews a plan the service has already made and saved, as it is.
    ///
    /// A tool's own cleanup is planned by `planToolCleanup`, which names
    /// the command rather than any paths. Handing its intent back to `plan`
    /// asked for a footprint of something called "npm cache clean --force"
    /// with no targets, so the plan reviewed was never the one offered.
    public func adopt(plan adopted: Plan, service: any BrimServiceProtocol) {
        self.service = service
        baseIntent = adopted.intent
        tickedByHand = []
        generation += 1
        isUpdating = false
        plan = adopted
        reviewGroups = Self.groupedSteps(adopted.steps)
        offerGroups = Self.groupedOffers(adopted.excludedItems)
        phase = .ready
    }

    /// Why the disk did not give back what was deleted.
    ///
    /// Deleting a file whose blocks are still referenced by a local
    /// snapshot frees nothing until that snapshot expires. Reporting the
    /// removal as a success and leaving the user to notice that their free
    /// space never moved is how a cleaning tool loses trust, so this says
    /// it plainly instead.
    public var spaceExplanation: String? {
        guard case let .verified(result) = phase, let plan else { return nil }
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
            let planned = plan.steps.filter(\.kind.targetIsPath).map(\.target)
            onRemoved?(result.removedPaths(from: planned))
        } catch {
            phase = .appliedButUnverified(error.localizedDescription)
            // The removal ran and only the proof failed, so the list cannot
            // be told anything about what went. It refreshes on dismissal,
            // which is the one case where waiting is the honest answer.
        }
    }
}
