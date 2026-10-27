import Foundation

extension StepKind {
    /// Whether this kind of step destroys something `undo` cannot put back.
    /// About the mechanism, not one target: a privacy grant cleared with
    /// `tccutil` is gone, a Launch Services registration comes back with undo.
    public var destroysWithoutRecovery: Bool {
        switch self {
        case .resetPrivacyGrants, .forgetReceipt, .delegateToolCleanup:
            return true
        case .unregisterLaunchServices, .unloadLaunchdJob, .clearImmutableFlag,
             .revealVendorUninstaller, .removeDockShortcut:
            return false
        case .trashPath, .trashPathPrivileged, .removeLaunchdPlist:
            // Depends on the disposition, which the step carries.
            return false
        }
    }
}

extension Step {
    /// Whether this step is worth interrupting a person for: it must destroy
    /// something nothing can restore, and it must matter. Asking before clearing
    /// a recreatable cache teaches people to approve without reading.
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

    /// The steps that make this plan worth authenticating for. Plan-aware,
    /// because one step's meaning depends on what runs beside it.
    public var stepsWarrantingHumanPresence: [Step] {
        let theApplicationIsLeaving = intent.type == .uninstall && removesTheApplicationBundle

        return steps.filter { step in
            guard step.warrantsHumanPresence else { return false }

            // A privacy grant is inert without its app, and macOS asks again if the app
            // ever returns, so clearing grants during an uninstall loses nothing and
            // needs no fingerprint. Clearing grants alone, with the app staying, still
            // asks.
            if step.kind == .resetPrivacyGrants && theApplicationIsLeaving { return false }

            return true
        }
    }
}

/// When Brim asks a person to prove they are there. The review is the
/// consent; a fingerprint only proves a person is at the Mac rather than
/// software driving the app. Worth one interruption before something is
/// destroyed beyond recovery, and none before a move to the Trash.
public struct ApprovalPolicy: Sendable, Equatable {

    /// How long a successful authentication covers further destructive work,
    /// like `sudo`'s timestamp, so three removals in a row cost one prompt.
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

    /// What the system prompt says Brim is trying to do. macOS shows "Brim is
    /// trying to ___", so this is a lowercase verb phrase with no full stop. It
    /// names only what cannot be undone.
    static func reason(for destructive: [Step], in plan: Plan) -> String {
        let subject = plan.intent.subjectIdentity.name
        let grantsCleared = destructive.contains { $0.kind == .resetPrivacyGrants }
        let receipts = destructive.filter { $0.kind == .forgetReceipt }.count
        // Receipts are counted separately: forgetting one deletes no file.
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
            // Nothing recognised, which should not happen; a general phrase is better
            // than naming nothing.
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
