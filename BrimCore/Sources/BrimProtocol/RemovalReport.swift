import BrimCore
import Darwin
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
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

    public enum PathPresence: String, Codable, Sendable { case present, unknown }

    /// A path excluded from execution, observed again during verification.
    public struct ProtectedItem: Codable, Equatable, Hashable, Sendable {
        public let target: String
        public let reason: String
        public let presence: PathPresence

        public init(target: String, reason: String, presence: PathPresence = .present) {
            self.target = target
            self.reason = reason
            self.presence = presence
        }
    }

    /// Identifier-wide permissions deliberately kept for another reviewed installation.
    public struct SharedIdentityProtection: Codable, Equatable, Sendable {
        public let identifier: String
        public let installations: [Identity]

        public init(identifier: String, installations: [Identity]) {
            self.identifier = identifier
            self.installations = installations
        }
    }

    /// Places the plan named, looked at again after the removal and gone.
    public let checkedGone: Int
    public let unknownPaths: [String]?
    /// Nil in legacy history. Preflight coverage never becomes fresh verification.
    public let registrationObservations: [RegistrationVerification]?
    public let completedActions: [String]?
    /// A failed command does not prove the affected records remain present.
    public let failedActions: [String]?
    /// Kinds of registration Brim searched macOS for, with nothing of the
    /// app's left.
    public let registrationsChecked: [DeclaredCapability]
    /// Kinds the app's bundle declares it does not have.
    public let declaredNone: [DeclaredCapability]
    /// What macOS kept, or would not let Brim look at.
    public let keptByMacOS: [Kept]
    /// Still there for another reason: written back, skipped, or failed.
    public let stillThere: Int
    /// Found, left unticked, and still on the disk. Antigravity's removal
    /// said "Nothing left" over four of these: every ticked item was gone,
    /// which is all the sentence was checking, and the person read it as
    /// everything.
    public let leftUnticked: [String]
    /// Excluded paths that are still present or whose absence could not be confirmed.
    public let protectedItems: [ProtectedItem]
    public let sharedIdentityProtection: SharedIdentityProtection?
    /// Gaps in discovery remain gaps after every selected item is gone.
    /// Nil for complete searches and reports saved before this field existed.
    public let scanCompleteness: ScanCompleteness?

    public init(
        checkedGone: Int, registrationsChecked: [DeclaredCapability], declaredNone: [DeclaredCapability],
        keptByMacOS: [Kept], stillThere: Int, leftUnticked: [String] = [],
        scanCompleteness: ScanCompleteness? = nil, protectedItems: [ProtectedItem] = [],
        sharedIdentityProtection: SharedIdentityProtection? = nil,
        unknownPaths: [String]? = nil,
        registrationObservations: [RegistrationVerification]? = nil,
        completedActions: [String]? = nil,
        failedActions: [String]? = nil
    ) {
        self.checkedGone = checkedGone
        self.unknownPaths = unknownPaths
        self.registrationObservations = registrationObservations
        self.completedActions = completedActions
        self.failedActions = failedActions
        self.registrationsChecked = registrationsChecked
        self.declaredNone = declaredNone
        self.keptByMacOS = keptByMacOS
        self.stillThere = stillThere
        self.leftUnticked = leftUnticked
        self.protectedItems = protectedItems
        self.sharedIdentityProtection = sharedIdentityProtection
        self.scanCompleteness = scanCompleteness?.isComplete == false ? scanCompleteness : nil
    }

    private enum CodingKeys: String, CodingKey {
        case checkedGone, registrationsChecked, declaredNone, keptByMacOS, stillThere, leftUnticked, scanCompleteness
        case protectedItems, sharedIdentityProtection, unknownPaths, registrationObservations
        case completedActions, failedActions
    }

    /// A report recorded before `leftUnticked` existed still reads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checkedGone = try container.decode(Int.self, forKey: .checkedGone)
        unknownPaths = try container.decodeIfPresent([String].self, forKey: .unknownPaths)
        registrationObservations = try container.decodeIfPresent(
            [RegistrationVerification].self,
            forKey: .registrationObservations
        )
        completedActions = try container.decodeIfPresent([String].self, forKey: .completedActions)
        failedActions = try container.decodeIfPresent([String].self, forKey: .failedActions)
        registrationsChecked = try container.decode([DeclaredCapability].self, forKey: .registrationsChecked)
        declaredNone = try container.decode([DeclaredCapability].self, forKey: .declaredNone)
        keptByMacOS = try container.decode([Kept].self, forKey: .keptByMacOS)
        stillThere = try container.decode(Int.self, forKey: .stillThere)
        leftUnticked = try container.decodeIfPresent([String].self, forKey: .leftUnticked) ?? []
        protectedItems = try container.decodeIfPresent([ProtectedItem].self, forKey: .protectedItems) ?? []
        sharedIdentityProtection = try container.decodeIfPresent(
            SharedIdentityProtection.self, forKey: .sharedIdentityProtection
        )
        scanCompleteness = try container.decodeIfPresent(ScanCompleteness.self, forKey: .scanCompleteness)
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
        survivingExtensions _: Set<String>?,
        capability: (String) -> Capability = { RemovalCapability.forDeleting($0) },
        exists: ((String) -> Bool)? = nil,
        unknownPaths: Set<String> = [],
        registrationObservations: [RegistrationVerification]? = nil,
        completedActions: [String] = [],
        verificationStartedAt: Date? = nil
    ) -> RemovalReport {
        let planned = Set(plan.steps.filter(\.kind.targetIsPath).map(\.target))
        let untickedObservations = Self.untickedObservations(in: plan, planned: planned, exists: exists)
        let unknown = unknownPaths.union(untickedObservations.filter(\.1.isUnknown).map(\.0))
        var kept: [Kept] = []
        var stillThere = 0
        for path in remaining.subtracting(unknownPaths).sorted() {
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

        let registrations = registrationSummary(plan: plan, observations: registrationObservations,
                                                verificationStartedAt: verificationStartedAt)
        kept += registrations.kept

        return RemovalReport(
            checkedGone: planned.subtracting(remaining.union(unknown)).count,
            registrationsChecked: registrations.checked,
            declaredNone: registrations.declaredNone,
            keptByMacOS: kept,
            stillThere: stillThere,
            leftUnticked: untickedObservations.filter(\.1.isPresent).map(\.0).sorted(),
            scanCompleteness: plan.scanCompleteness,
            protectedItems: plan.excludedItems
                .filter { $0.canBeTickedByHand != true && !planned.contains($0.target) }
                .compactMap { observedProtectedItem($0, exists: exists) }
                .sorted { $0.target < $1.target },
            sharedIdentityProtection: sharedIdentityProtection(in: plan),
            unknownPaths: unknown.sorted(),
            registrationObservations: registrationObservations,
            completedActions: completedActions,
            failedActions: privacyResetFailed ? ["Permission reset command did not complete."] : []
        )
    }

    private static func untickedObservations(in plan: Plan, planned: Set<String>,
                                             exists: ((String) -> Bool)?) -> [(String, PathObservation)] {
        plan.excludedItems.filter {
            $0.canBeTickedByHand == true && !planned.contains($0.target)
        }.map { item in
            (item.target, exists.map { $0(item.target) ? PathObservation.present : .absent }
                ?? PathObservation.observe(item.target))
        }
    }

    private static func registrationSummary(
        plan: Plan, observations: [RegistrationVerification]?, verificationStartedAt: Date?
    ) -> RemovalRegistrationSummary {
        let declaredNone = (plan.capabilityReport?.checks ?? [])
            .filter { $0.declaration == .notDeclared && $0.registrations.isEmpty }
            .map(\.capability)
        // Declarations are useful review evidence, but do not certify absence.
        let grouped = Dictionary(grouping: observations ?? [], by: \.capability)
        let checked = DeclaredCapability.allCases.filter { capability in
            guard let reads = grouped[capability], !reads.isEmpty else { return false }
            return reads.allSatisfy { observation in
                verificationStartedAt.map { observation.confirmsClear(since: $0) } ?? observation.confirmedClear
            }
        }
        return RemovalRegistrationSummary(checked: checked, declaredNone: declaredNone, kept: [])
    }

    private static func sharedIdentityProtection(in plan: Plan) -> SharedIdentityProtection? {
        guard plan.intent.type == .uninstall, plan.intent.explicitTargets.isEmpty,
              let identifier = plan.intent.subjectIdentity.bundleID,
              let copies = plan.survivingCopies, !copies.isEmpty,
              !plan.steps.contains(where: { $0.kind == .resetPrivacyGrants }),
              plan.steps.contains(where: {
                  $0.executionPhase == .appBundle && ($0.kind == .trashPath || $0.kind == .trashPathPrivileged)
              }) else { return nil }
        return SharedIdentityProtection(identifier: identifier, installations: copies)
    }

    private static func observedProtectedItem(
        _ item: ExcludedItem, exists: ((String) -> Bool)?
    ) -> ProtectedItem? {
        guard item.target.hasPrefix("/") else { return nil }
        if let exists {
            return exists(item.target) ? ProtectedItem(target: item.target, reason: item.reason) : nil
        }
        switch PathObservation.observe(item.target) {
        case .present: return ProtectedItem(target: item.target, reason: item.reason)
        case .absent: return nil
        case .unknown: return ProtectedItem(target: item.target, reason: item.reason, presence: .unknown)
        }
    }
}

private struct RemovalRegistrationSummary {
    let checked: [DeclaredCapability]
    let declaredNone: [DeclaredCapability]
    let kept: [RemovalReport.Kept]
}
