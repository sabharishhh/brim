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
        case .resetPrivacyGrants, .forgetReceipt, .delegateToolCleanup:
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
    /// Whether this plan takes the application bundle itself away.
    public var removesTheApplicationBundle: Bool {
        steps.contains { $0.executionPhase == .appBundle }
    }

    /// The steps that make this plan worth authenticating for, if any.
    ///
    /// Plan-aware rather than step-local, because one step changes meaning
    /// depending on what runs beside it.
    public var stepsWarrantingHumanPresence: [Step] {
        let theApplicationIsLeaving = intent.type == .uninstall && removesTheApplicationBundle

        return steps.filter { step in
            guard step.warrantsHumanPresence else { return false }

            // A privacy grant is a permission macOS holds *for a bundle*. Let
            // it go along with the bundle and nothing is lost that anybody
            // could want back: the grant is inert without the application,
            // macOS asks again from scratch if the application ever returns,
            // and declining the prompt would not keep anything either, since
            // the application is being removed regardless.
            //
            // This step is emitted for every uninstall of every application
            // that has an identifier, which is very nearly all of them, so
            // treating it as prompt-worthy made a fingerprint the price of
            // the product's main action. That is the failure this whole file
            // exists to prevent, arrived at by being careful rather than by
            // being careless.
            //
            // Clearing grants on their own is a different matter and still
            // asks, because there the permissions are the only thing changing
            // and the application stays behind without them.
            if step.kind == .resetPrivacyGrants && theApplicationIsLeaving { return false }

            return true
        }
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
                    ? "Everything here can be fished back out of the Trash."
                    : "Nothing here destroys anything worth stopping you for."
            )
        }

        if let lastAuthenticated,
           now.timeIntervalSince(lastAuthenticated) < graceWindow,
           now >= lastAuthenticated {
            return .alreadyGiven(because: "You proved it was you a moment ago.")
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
        let receipts = destructive.filter { $0.kind == .forgetReceipt }.count
        // Receipts are counted separately below. Rolling them into "items"
        // said "permanently delete 1 item" about a step that deletes no file
        // at all, which is the kind of small inaccuracy that teaches somebody
        // the prompt is not worth reading.
        let permanentCount = destructive
            .filter { $0.effectiveDisposition == .delete && $0.kind != .forgetReceipt }
            .count

        var clauses: [String] = []
        if permanentCount == 1 {
            clauses.append("permanently delete 1 item belonging to \(subject)")
        } else if permanentCount > 1 {
            clauses.append("permanently delete \(permanentCount) items belonging to \(subject)")
        }
        if receipts > 0 {
            clauses.append(
                receipts == 1
                    ? "discard the installer record for \(subject)"
                    : "discard \(receipts) installer records for \(subject)"
            )
        }
        if grantsCleared {
            clauses.append("clear the privacy permissions macOS holds for \(subject)")
        }

        guard !clauses.isEmpty else {
            // Nothing recognised, which should not happen, but a prompt that
            // names nothing is worse than a general one.
            return "make a change to \(subject) that cannot be undone"
        }

        let joined: String
        switch clauses.count {
        case 1: joined = clauses[0]
        case 2: joined = "\(clauses[0]) and \(clauses[1])"
        default: joined = clauses.dropLast().joined(separator: ", ") + ", and " + clauses[clauses.count - 1]
        }
        return joined + ", which cannot be undone"
    }
}
