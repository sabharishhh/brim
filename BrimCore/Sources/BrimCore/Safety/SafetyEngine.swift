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

    public func evaluate(footprint: Footprint, useCachedProtection: Bool = false) async -> EvaluatedFootprint {
        // A footprint is a claim about what is on the disk, and a search that did
        // not finish cannot support it, so nothing from an unfinished pass is
        // selected. Everything is still shown, and every row can be ticked by hand.
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

            // 2. Cost-of-error annotation based on path
            let cost = item.artifactClassification?.costOfError ?? evaluateCostOfError(url: url)
            if let kept = Self.preservedData(item, identity: footprint.identity) {
                return kept
            }

            // 3. Tier defaults. S is not a confidence: something else on this Mac
            // claims the item, so it leaves the selection and cannot re-enter it.
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
                searchFinished && (Self.isClearlyNamedData(url, for: footprint.identity)
                    || Self.isNamedRebuildable(item, for: footprint.identity))
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
        return await vetoEngine.applyVeto(to: preVeto, useCachedProtection: useCachedProtection)
    }

    /// The folders an app keeps its own data in, where a folder clearly named
    /// for it goes with it. Elsewhere a name can mean more (`~/.docker` holds
    /// credentials), so it stays a suggestion.
    static let namedDataFolders = [
        "Library/Application Support", "Library/Caches", "Library/Logs", "Library/HTTPStorages",
        "Library/WebKit", "Library/Saved Application State"
    ]

    static func isClearlyNamedData(_ url: URL, for identity: Identity) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        guard namedDataFolders.contains(where: { parent.hasSuffix("/" + $0) }) else { return false }
        return identity.isClearlyNamed(url.lastPathComponent)
    }

    /// Crash reports and suffixed cache/log names were left for individual
    /// clicks even when the inventory proved the app's name and location.
    /// Timing-only recordings and names outside these folders stay optional.
    static func isNamedRebuildable(_ item: FootprintItem, for identity: Identity) -> Bool {
        guard item.evidence.mechanism == "LocationInventorySource" else { return false }
        let url = item.evidence.url
        let parent = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        if parent.hasSuffix("/Library/Logs/DiagnosticReports") {
            return identity.ownNames.contains { LocationInventory.Location.isReport(name, of: $0) }
        }
        guard parent.hasSuffix("/Library/Caches") || parent.hasSuffix("/Library/Logs") else { return false }
        return name.indices.contains { index in
            name[index] == "-" && name.index(after: index) < name.endIndex
                && identity.isClearlyNamed(String(name[..<index]))
        }
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

        // A path named Caches or tmp can hold settings and local changes, so
        // permanent removal needs a positive classification. Documents and iCloud
        // Drive are the highest cost.
        if path.contains("/Documents/") || path.contains("/Mobile Documents/") {
            return .high
        }

        // Application Support and Preferences are medium
        return .medium
    }
}
