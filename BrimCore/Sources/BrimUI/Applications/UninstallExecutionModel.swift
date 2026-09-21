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
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .preparing
    @Published public private(set) var plan: Plan?

    private var service: (any BrimServiceProtocol)?

    public init() {}

    public var isBusy: Bool {
        switch phase {
        case .preparing, .executing: return true
        case .ready, .verified, .failed: return false
        }
    }

    public var canAuthorize: Bool {
        guard case .ready = phase, let plan else { return false }
        return !plan.steps.isEmpty
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
        phase = .preparing
        do {
            let planned = try await service.plan(intent: intent)
            plan = planned
            phase = .ready
        } catch {
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

    /// One authorization for the whole plan, then apply, then verify.
    public func authorize(requesterIdentity: String) async {
        guard let service, let plan, case .ready = phase else { return }

        phase = .executing
        do {
            let token = try await service.requestApproval(
                planId: plan.planId, requesterIdentity: requesterIdentity
            )
            try await service.apply(planId: plan.planId, token: token)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // Applied. Now prove it: a failure to verify is reported, not
        // swallowed, because an unverified removal is the thing this product
        // exists to avoid.
        do {
            phase = .verified(try await service.verify(planId: plan.planId))
        } catch {
            phase = .failed("Removed, but verification could not run: \(error.localizedDescription)")
        }
    }
}
