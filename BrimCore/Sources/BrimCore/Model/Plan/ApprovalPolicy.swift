import Foundation

extension StepKind {
    /// Whether this kind of step destroys something `undo` cannot put back.
    ///
    /// Not the same as `Step.reversible`, which records what the planner
    /// believed about one target. This is about the mechanism: a privacy
    /// grant cleared with `tccutil` is gone for good, while a Launch
    /// Services registration is put back by `undo` along with the bundle.
    public var destroysWithoutRecovery: Bool {
        switch self {
        case .resetPrivacyGrants, .forgetReceipt, .btmReset, .delegateToolCleanup:
            return true
        case .unregisterLaunchServices, .unloadLaunchdJob, .clearImmutableFlag,
             .revealVendorUninstaller, .archivePath:
            return false
        case .trashPath, .trashPathPrivileged, .removeLaunchdPlist:
            // Depends on the disposition, which the step carries.
            return false
        }
    }
}

extension Step {
    /// Whether this step is worth interrupting a human for.
    ///
    /// Two conditions, both required. It must destroy something nothing can
    /// restore — and it must matter. A recreatable cache is deleted outright
    /// by design, and asking for a fingerprint before clearing one is how a
    /// user learns to approve without reading.
    public var warrantsHumanPresence: Bool {
        guard costOfError != .low else { return false }
        return kind.destroysWithoutRecovery || effectiveDisposition == .delete
    }
}

extension Plan {
    /// The steps that make this plan worth authenticating for, if any.
    public var stepsWarrantingHumanPresence: [Step] {
        steps.filter(\.warrantsHumanPresence)
    }
}

/// When Brim asks a human to prove they are there.
///
/// Authentication is not consent — the review sheet is consent, and the user
/// has already read what will happen and pressed a button saying to do it.
/// A fingerprint proves something narrower: that a person is at the machine
/// at this moment, rather than software driving the app. That is worth one
/// interruption before something is destroyed beyond recovery, and worth
/// nothing at all before a file is moved to the Trash.
///
/// The failure this exists to prevent is not an unauthorised deletion. It is
/// a user who has been asked so often that they approve without looking, at
/// which point every prompt in the product has become decoration.
public struct ApprovalPolicy: Sendable, Equatable {

    /// How long a successful authentication covers further destructive work.
    ///
    /// The same idea as `sudo`'s timestamp and macOS's own
    /// `authenticate-user` timeout: a person who proved they were present a
    /// moment ago is still present. Without it, clearing three applications
    /// in a row costs three interruptions for one decision.
    public let graceWindow: TimeInterval

    public init(graceWindow: TimeInterval = 300) {
        self.graceWindow = graceWindow
    }

    public enum Requirement: Equatable, Sendable {
        /// Proceed on the approval already given in the UI.
        case alreadyGiven(because: String)
        /// Ask for a fingerprint or password, with this reason shown.
        case humanPresence(reason: String)

        public var needsPrompt: Bool {
            if case .humanPresence = self { return true }
            return false
        }
    }

    /// What this plan requires, given when a human last proved they were here.
    public func requirement(
        for plan: Plan,
        lastAuthenticated: Date?,
        now: Date = Date()
    ) -> Requirement {
        let destructive = plan.stepsWarrantingHumanPresence
        guard !destructive.isEmpty else {
            return .alreadyGiven(
                because: plan.isReversible
                    ? "Everything in this plan can be recovered from the Trash."
                    : "Nothing in this plan destroys anything that matters."
            )
        }

        if let lastAuthenticated,
           now.timeIntervalSince(lastAuthenticated) < graceWindow,
           now >= lastAuthenticated {
            return .alreadyGiven(because: "You confirmed it was you a moment ago.")
        }

        return .humanPresence(reason: Self.reason(for: destructive, in: plan))
    }

    /// What the system prompt says Brim is trying to do.
    ///
    /// macOS renders this as "Brim is trying to _____", so it must be a
    /// lowercase verb phrase with no trailing full stop. Written as a
    /// sentence it comes out as "Brim is trying to Remove Figma, clear the
    /// privacy permissions…." — which is how the first version read.
    ///
    /// It names what cannot be undone, because that is the only thing the
    /// prompt is asking about.
    static func reason(for destructive: [Step], in plan: Plan) -> String {
        let subject = plan.intent.subjectIdentity.name
        let grantsCleared = destructive.contains { $0.kind == .resetPrivacyGrants }
        let permanentCount = destructive.filter { $0.effectiveDisposition == .delete }.count

        if grantsCleared && permanentCount > 1 {
            return "remove \(subject) and permanently delete \(permanentCount) items, "
                 + "including the privacy permissions macOS holds for it — this cannot be undone"
        }
        if grantsCleared {
            return "remove \(subject) and clear the privacy permissions macOS holds for it "
                 + "— this cannot be undone"
        }
        if permanentCount == 1 {
            return "permanently delete 1 item belonging to \(subject) — this cannot be undone"
        }
        return "permanently delete \(permanentCount) items belonging to \(subject) "
             + "— this cannot be undone"
    }
}
