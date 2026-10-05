import Foundation

// swiftformat:disable wrapMultilineStatementBraces
public enum SelectionState: Equatable, Sendable {
    case selected
    case unselected
    case excluded(reason: String)
}

public struct EvaluatedItem: Equatable, Sendable {
    public let footprintItem: FootprintItem
    public let selection: SelectionState
    public let costOfError: CostOfError

    public init(footprintItem: FootprintItem, selection: SelectionState, costOfError: CostOfError) {
        self.footprintItem = footprintItem
        self.selection = selection
        self.costOfError = costOfError
    }
}

public struct EvaluatedFootprint: Equatable, Sendable {
    public let identity: Identity
    public let items: [EvaluatedItem]
    public let completeness: ScanCompleteness
    /// Other installations claiming this app's identifier. Paths are kept
    /// because an identifier alone cannot distinguish installed copies.
    public let survivingCopies: [Identity]
    public let protectedComponentIdentifiers: [String]

    public init(
        identity: Identity, items: [EvaluatedItem], completeness: ScanCompleteness = .complete,
        survivingCopies: [Identity] = [], protectedComponentIdentifiers: [String] = []
    ) {
        self.identity = identity
        self.items = items
        self.completeness = completeness
        self.survivingCopies = survivingCopies
        self.protectedComponentIdentifiers = protectedComponentIdentifiers.sorted()
    }
}

/// The only component that may decide what gets selected for removal.
public struct SafetyEngine: Sendable {
    public let safetyChecker: SafetyChecker
    public let vetoEngine: TierSVetoEngine

    public init(safetyChecker: SafetyChecker, vetoEngine: TierSVetoEngine) {
        self.safetyChecker = safetyChecker
        self.vetoEngine = vetoEngine
    }

    public func evaluate(footprint: Footprint) async -> EvaluatedFootprint {
        // Mole degrades a timed-out ownership scan and narrows the plan
        // rather than removing shared leftovers, and Brim's own invariant
        // says degrade, never fail. This is the concrete form of it.
        //
        // The rule is not "be careful when the scan was slow". A
        // footprint is a claim about what is on the disk, and a search
        // that did not finish cannot support the claim, so nothing found
        // in an unfinished pass is selected for the person. Everything is
        // still shown, and every row can still be ticked by hand.
        let searchFinished = footprint.completeness.isComplete

        let evaluatedItems = footprint.items.map { item -> EvaluatedItem in
            let url = item.evidence.url

            // 1. Absolute Deny List (via SafetyChecker)
            let isSelfRemoval = safetyChecker.isBrimItself(footprint.identity.bundleID)
            if !safetyChecker.isSafeToRemove(url: url, isSelfRemoval: isSelfRemoval) {
                return EvaluatedItem(
                    footprintItem: item,
                    selection: .excluded(
                        reason: "Path is strictly protected by OS boundaries or is the Brim app itself."
                    ),
                    costOfError: .high
                )
            }

            // Note: in a real implementation, we would check if it's on a strictly protected volume,
            // or outside the known domain map here if SafetyChecker didn't catch it.

            // 2. Cost-of-error annotation based on path
            let cost = item.artifactClassification?.costOfError ?? evaluateCostOfError(url: url)
            if let kept = Self.preservedData(item, identity: footprint.identity) {
                return kept
            }

            // 3. Tier defaults. S is not a confidence level: it says
            // something else on this Mac claims this item, so it leaves
            // the selection and cannot re-enter it.
            let selection: SelectionState = switch item.evidence.tier {
            case .S:
                .excluded(
                    reason: "Shared with other installed software."
                )
            case .A, .B:
                searchFinished
                    ? .selected
                    : .unselected
            case .C:
                searchFinished && Self.isClearlyNamedData(url, for: footprint.identity)
                    ? .selected
                    : .unselected
            }

            return EvaluatedItem(
                footprintItem: item,
                selection: selection,
                costOfError: cost
            )
        }

        let preVeto = EvaluatedFootprint(
            identity: footprint.identity, items: evaluatedItems, completeness: footprint.completeness
        )
        return await vetoEngine.applyVeto(to: preVeto)
    }

    /// The folders an application keeps its own data in, where a folder
    /// clearly named for it is its own and goes with it.
    ///
    /// A name match was never ticked, so `Application Support/SystemEQ for
    /// Mac` was found and stayed behind, in the folder people open first
    /// when they check whether a removal was complete. Elsewhere a name can
    /// mean more than one thing (`~/.docker` holds credentials, Services
    /// can be the person's own), so those stay suggestions.
    static let namedDataFolders = [
        "Library/Application Support", "Library/Caches", "Library/Logs", "Library/HTTPStorages",
        "Library/WebKit", "Library/Saved Application State"
    ]

    static func isClearlyNamedData(_ url: URL, for identity: Identity) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        guard namedDataFolders.contains(where: { parent.hasSuffix("/" + $0) }) else { return false }
        return identity.isClearlyNamed(url.lastPathComponent)
    }

    private static func preservedData(_ item: FootprintItem, identity: Identity) -> EvaluatedItem? {
        if item.artifactClassification == .toolManaged {
            return EvaluatedItem(footprintItem: item,
                                 selection: .excluded(reason: "Managed by its tool. Use its cleanup action."),
                                 costOfError: .medium)
        }
        if item.artifactClassification == .stateful {
            return EvaluatedItem(footprintItem: item,
                                 selection: .excluded(reason: "Stateful artifact. Manage it with its owning tool."),
                                 costOfError: .high)
        }

        if identity.capabilitySurface?.state(for: .fileProvider) == .declared,
           item.evidence.url.path != identity.bundlePath,
           !(identity.bundlePath.map { item.evidence.url.path.hasPrefix($0 + "/") } ?? false),
           ["/Containers/", "/Group Containers/", "/CloudStorage/", "/Application Support/", "/Mobile Documents/"]
           .contains(where: {
               item.evidence.url.path.contains($0)
           }) {
            return EvaluatedItem(footprintItem: item,
                                 selection: .excluded(
                                     reason: "Cloud provider data is kept. Finish syncing or export it with the owning app."
                                 ),
                                 costOfError: .high)
        }

        return nil
    }

    private func evaluateCostOfError(url: URL) -> CostOfError {
        let path = url.path

        // A path named Caches or tmp can contain settings and local changes.
        // Permanent removal requires a positive artifact classification.
        // Documents or iCloud drives are very high cost
        if path.contains("/Documents/") || path.contains("/Mobile Documents/") {
            return .high
        }

        // Application Support and Preferences are medium
        return .medium
    }
}
