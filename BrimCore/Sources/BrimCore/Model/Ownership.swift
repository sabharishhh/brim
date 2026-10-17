import Foundation

/// The search that must come back empty before anything is called a
/// leftover, and whose result decides which kind. The question is not
/// whether a file is still wanted but whether an owner can be found, which
/// evidence can answer. The verdict carries the sentence saying which source
/// answered.
public enum Ownership: Equatable, Sendable {
    /// An owner is installed and present, so this is not a leftover at all.
    case present(owner: URL)

    /// Something recorded an owner and it has gone: the definition of orphaned.
    case recordedButGone(evidence: String)

    /// An owner lookup failed. Older absence records cannot resolve whether
    /// another installed copy now claims this data.
    case unknown(evidence: String)

    /// Nothing claims it. Unclaimed: shown, never pre-selected, because no
    /// evidence of an owner is not evidence there is none.
    case unattributable

    public var category: Leftover.Category? {
        switch self {
        case .present: nil
        case .recordedButGone: .orphaned
        case .unattributable, .unknown: .unclaimed
        }
    }
}

/// Resolves ownership for an identifier against every source that can record
/// one. Sources are injected so the ordering can be tested.
public struct OwnershipSearch: Sendable {
    /// Bundle identifiers of applications found on disk, across all mounted
    /// volumes and every readable user account, not just `/Applications`.
    public let installedBundleIDs: Set<String>
    /// Lowercased names of those same applications, for the many directories
    /// named after an app rather than its identifier.
    public let installedNames: Set<String>
    /// The same names compared as `NameKey` compares them, so `Codex` and
    /// `codex-app` agree with the removal about whose a folder is.
    let installedNameKeys: Set<String>
    /// Identifiers with an installer receipt in `/var/db/receipts`.
    public let receiptBundleIDs: Set<String>
    /// Identifiers Brim itself has removed, from its own ledger.
    public let previouslyRemovedBundleIDs: Set<String>
    /// Identifiers named by a registration (a launchd job, a background item,
    /// an installer receipt) whose program is gone, with the sentence describing
    /// it: macOS still holding a record of software that has left.
    public let staleRegistrationOwners: [String: String]
    /// Launch Services' answer for an identifier: every location it still
    /// associates with that bundle.
    public let launchServicesLookup: @Sendable (String) throws -> [URL]
    /// Whether a path exists. Injected so the ordering can be tested.
    public let exists: @Sendable (URL) -> Bool

    public init(
        installedBundleIDs: Set<String>,
        installedNames: Set<String>,
        receiptBundleIDs: Set<String>,
        previouslyRemovedBundleIDs: Set<String>,
        staleRegistrationOwners: [String: String] = [:],
        launchServicesLookup: @escaping @Sendable (String) throws -> [URL],
        exists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.installedBundleIDs = installedBundleIDs
        self.installedNames = installedNames
        installedNameKeys = Set(installedNames.map(NameKey.of).filter { !$0.isEmpty })
        self.receiptBundleIDs = receiptBundleIDs
        self.previouslyRemovedBundleIDs = previouslyRemovedBundleIDs
        self.staleRegistrationOwners = staleRegistrationOwners
        self.launchServicesLookup = launchServicesLookup
        self.exists = exists
    }

    /// Looks for an owner, strongest evidence first. Presence on real volumes is
    /// checked before Launch Services, so an app on an unusual volume is never
    /// called orphaned on the strength of a database.
    public func ownership(of identifier: String) -> Ownership {
        let installed = installedBundleIDs.contains(identifier) || installedNames.contains(identifier.lowercased())
            || installedNameKeys.contains(NameKey.of(identifier))
        if installed {
            return .present(owner: URL(fileURLWithPath: "/"))
        }

        // A Launch Services record whose bundle is still there is an owner the walk
        // missed; one whose bundle has gone is the cleanest orphan evidence, since
        // macOS itself recorded the app as installed.
        let registered: [URL]
        do {
            registered = try launchServicesLookup(identifier)
        } catch {
            return .unknown(evidence: "Launch Services could not check whether \(identifier) is still installed.")
        }
        if let live = registered.first(where: exists) {
            return .present(owner: live)
        }
        if let stale = registered.first {
            return .recordedButGone(
                evidence: "Launch Services lists \(stale.path), but the app is gone."
            )
        }

        if let registration = staleRegistrationOwners[identifier] {
            return .recordedButGone(evidence: registration)
        }

        if receiptBundleIDs.contains(identifier) {
            return .recordedButGone(
                evidence: "An installer receipt names \(identifier), but the app is gone."
            )
        }

        if previouslyRemovedBundleIDs.contains(identifier) {
            return .recordedButGone(
                evidence: "Brim removed this app. This file remains."
            )
        }

        return .unattributable
    }
}
