import Foundation

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
        let evaluatedItems = footprint.items.map { item -> EvaluatedItem in
            let url = item.evidence.url
            
            // 1. Absolute Deny List (via SafetyChecker)
            let isSelfRemoval = footprint.identity.bundleID == "devplaceholder.PJ52YXEB.brim" || footprint.identity.bundleID == "com.google.Brim"
            if !safetyChecker.isSafeToRemove(url: url, isSelfRemoval: isSelfRemoval) {
                return EvaluatedItem(
                    footprintItem: item,
                    selection: .excluded(reason: "Path is strictly protected by OS boundaries or is the Brim app itself."),
                    costOfError: .high
                )
            }
            
            // Note: in a real implementation, we would check if it's on a strictly protected volume,
            // or outside the known domain map here if SafetyChecker didn't catch it.
            
            // 2. Cost-of-error annotation based on path
            let cost = evaluateCostOfError(url: url)
            
            // 3. Tier Defaults
            let selection: SelectionState
            switch item.evidence.tier {
            case .S:
                selection = .selected
            case .A, .B:
                selection = .selected
            case .C:
                selection = .unselected
            }
            
            return EvaluatedItem(
                footprintItem: item,
                selection: selection,
                costOfError: cost
            )
        }
        
        let preVeto = EvaluatedFootprint(identity: footprint.identity, items: evaluatedItems)
        return await vetoEngine.applyVeto(to: preVeto)
    }
    
    private func evaluateCostOfError(url: URL) -> CostOfError {
        let path = url.path
        
        // Caches and temp files are low cost if accidentally deleted
        if path.contains("/Caches/") || path.contains("/tmp/") {
            return .low
        }
        
        // Documents or iCloud drives are very high cost
        if path.contains("/Documents/") || path.contains("/Mobile Documents/") {
            return .high
        }
        
        // Application Support and Preferences are medium
        return .medium
    }
}
