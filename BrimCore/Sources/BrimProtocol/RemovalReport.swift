import Foundation
import BrimCore

/// What a removal can honestly say afterwards, in three parts.
///
/// "Every location checked again" was one sentence covering three different
/// facts. Some things Brim looked at after the removal and found gone. Some
/// kinds of registration the app's own bundle says it never had, so there was
/// nothing to find. And some things macOS kept, or would not let Brim read.
/// Folding them together is how a removal ends up claiming more than it
/// checked, so each is counted on its own and nothing moves between them.
public struct RemovalReport: Codable, Equatable, Sendable {
    /// Something that is still there because macOS decides, not Brim.
    public struct Kept: Codable, Equatable, Hashable, Sendable {
        public let what: String
        public let why: String

        public init(what: String, why: String) {
            self.what = what
            self.why = why
        }
    }

    /// Places the plan named, looked at again after the removal and gone.
    public let checkedGone: Int
    /// Kinds of registration Brim searched macOS for, with nothing of the
    /// app's left.
    public let registrationsChecked: [DeclaredCapability]
    /// Kinds the app's bundle declares it does not have.
    public let declaredNone: [DeclaredCapability]
    /// What macOS kept, or would not let Brim look at.
    public let keptByMacOS: [Kept]
    /// Still there for another reason: written back, skipped, or failed.
    public let stillThere: Int

    public init(
        checkedGone: Int, registrationsChecked: [DeclaredCapability], declaredNone: [DeclaredCapability],
        keptByMacOS: [Kept], stillThere: Int
    ) {
        self.checkedGone = checkedGone
        self.registrationsChecked = registrationsChecked
        self.declaredNone = declaredNone
        self.keptByMacOS = keptByMacOS
        self.stillThere = stillThere
    }

    /// Built from the plan, what is still on the disk, and what the journal
    /// recorded for it.
    ///
    /// A path counts as kept by macOS only when the journal says the system
    /// refused, or nothing was recorded and the path is one macOS protects.
    /// A file an app wrote back, or a step that failed for its own reasons,
    /// is still there, and saying macOS kept it would be a claim about who
    /// is responsible that nothing supports.
    public static func build(
        plan: Plan,
        remaining: Set<String>,
        recorded: [String: String],
        staleRegistrations: Int,
        privacyResetFailed: Bool,
        survivingExtensions: Set<String>?,
        capability: (String) -> Capability = { RemovalCapability.forDeleting($0) }
    ) -> RemovalReport {
        let planned = Set(plan.steps.filter(\.kind.targetIsPath).map(\.target))
        var kept: [Kept] = []
        var stillThere = 0
        for path in remaining.sorted() {
            let outcome = recorded[path]
            let protected = capability(path)
            let refused = outcome == "refusedByOS" || (outcome == nil && protected != .ok)
            guard refused else {
                stillThere += 1
                continue
            }
            kept.append(Kept(
                what: (path as NSString).lastPathComponent,
                why: RemovalCapability.explanation(protected == .ok ? .refusedByOS : protected)
                    ?? "macOS would not let it move."
            ))
        }
        if staleRegistrations > 0 {
            kept.append(Kept(what: "File and URL associations",
                             why: "macOS still has the app registered."))
        }
        if privacyResetFailed {
            kept.append(Kept(what: "Privacy permissions",
                             why: "macOS did not clear them."))
        }

        var checked: [DeclaredCapability] = []
        var declaredNone: [DeclaredCapability] = []
        for check in plan.capabilityReport?.checks ?? [] {
            if !check.coverage.available {
                // Not looked at is not nothing found. A boundary Brim keeps on
                // purpose is not macOS's refusal either, so it is left out.
                guard check.coverage.absence != .byDesign else { continue }
                kept.append(Kept(what: check.capability.title,
                                 why: check.coverage.limitation ?? "Brim could not read this part of macOS."))
                continue
            }
            let found = !check.registrations.isEmpty
            if check.declaration == .notDeclared, !found {
                declaredNone.append(check.capability)
                continue
            }
            // Only macOS can take these, and for system extensions it is known
            // afterwards whether it did.
            let survived: Bool
            switch check.capability {
            case .systemExtension:
                let ids = Set(check.registrations.map(\.identifier))
                survived = found && (survivingExtensions.map { !$0.isDisjoint(with: ids) } ?? true)
            default:
                survived = found && check.removalTier == .detectableOnly
            }
            if survived {
                kept.append(Kept(what: check.capability.title,
                                 why: check.followUp?.sentence ?? "Only macOS can remove these."))
            } else {
                checked.append(check.capability)
            }
        }

        return RemovalReport(
            checkedGone: planned.subtracting(remaining).count,
            registrationsChecked: checked,
            declaredNone: declaredNone,
            keptByMacOS: kept,
            stillThere: stillThere
        )
    }
}
