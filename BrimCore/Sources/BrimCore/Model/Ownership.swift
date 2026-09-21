import Foundation

/// The search that must come back empty before anything is called a leftover,
/// and whose result decides which kind of leftover it is.
///
/// The distinction the product rests on is not "is this file still wanted"
/// but "can an owner be found for it". Those are different questions, and
/// only the second one can be answered with evidence. So this names every
/// place an owner can be recorded, and the verdict carries the sentence
/// explaining which of them answered.
public enum Ownership: Equatable, Sendable {

    /// An owner is installed and present, so this is not a leftover at all.
    case present(owner: URL)

    /// Something recorded an owner as installed and it is no longer there.
    /// This is the definition of *orphaned*: not "nobody claims it" but
    /// "somebody did, and they have gone".
    case recordedButGone(evidence: String)

    /// Nothing anywhere claims it. *Unclaimed* — shown, never pre-selected,
    /// because an absence of evidence is not evidence of absence.
    case unattributable

    public var category: Leftover.Category? {
        switch self {
        case .present: return nil
        case .recordedButGone: return .orphaned
        case .unattributable: return .unclaimed
        }
    }
}

/// Resolves ownership for an identifier against every source that can record
/// one.
///
/// Every source is injected rather than read here, so the ordering below can
/// be tested without a machine that happens to have the right software on it.
public struct OwnershipSearch: Sendable {

    /// Bundle identifiers of applications found on disk — across all mounted
    /// volumes and every readable user account, not just `/Applications`.
    public let installedBundleIDs: Set<String>
    /// Lowercased names of those same applications, for the many directories
    /// named after an app rather than its identifier.
    public let installedNames: Set<String>
    /// Identifiers with an installer receipt in `/var/db/receipts`.
    public let receiptBundleIDs: Set<String>
    /// Identifiers Brim itself has removed, from its own ledger.
    public let previouslyRemovedBundleIDs: Set<String>
    /// Launch Services' answer for an identifier: every location it still
    /// associates with that bundle.
    public let launchServicesLookup: @Sendable (String) -> [URL]
    /// Whether a path exists. Injected so the ordering can be tested.
    public let exists: @Sendable (URL) -> Bool

    public init(
        installedBundleIDs: Set<String>,
        installedNames: Set<String>,
        receiptBundleIDs: Set<String>,
        previouslyRemovedBundleIDs: Set<String>,
        launchServicesLookup: @escaping @Sendable (String) -> [URL],
        exists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.installedBundleIDs = installedBundleIDs
        self.installedNames = installedNames
        self.receiptBundleIDs = receiptBundleIDs
        self.previouslyRemovedBundleIDs = previouslyRemovedBundleIDs
        self.launchServicesLookup = launchServicesLookup
        self.exists = exists
    }

    /// Looks for an owner, strongest evidence first.
    ///
    /// The order is deliberate. Presence beats every other signal, and it is
    /// checked against real applications on real volumes before Launch
    /// Services is asked — because an app on an unmounted or unusual volume
    /// must never be reported as orphaned on the strength of a database.
    public func ownership(of identifier: String) -> Ownership {
        if installedBundleIDs.contains(identifier)
            || installedNames.contains(identifier.lowercased()) {
            return .present(owner: URL(fileURLWithPath: "/"))
        }

        // Launch Services answers both questions at once. A record whose
        // bundle is still there is an owner the directory walk missed; a
        // record whose bundle has gone is the cleanest orphan evidence there
        // is, because macOS itself recorded the app as installed.
        let registered = launchServicesLookup(identifier)
        if let live = registered.first(where: exists) {
            return .present(owner: live)
        }
        if let stale = registered.first {
            return .recordedButGone(
                evidence: "macOS still lists an application with this identifier at "
                        + "\(stale.path), which is no longer there."
            )
        }

        if receiptBundleIDs.contains(identifier) {
            return .recordedButGone(
                evidence: "An installer receipt records this identifier, but the "
                        + "software it installed is not on this Mac."
            )
        }

        if previouslyRemovedBundleIDs.contains(identifier) {
            return .recordedButGone(
                evidence: "Brim removed this application, and this was left behind."
            )
        }

        return .unattributable
    }
}
