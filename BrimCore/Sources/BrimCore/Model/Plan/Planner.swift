import Foundation

/// The system component that generates an executable plan from an evaluated footprint.
public struct Planner: Sendable {
    
    public init() {}
    
    public func createPlan(from evaluatedFootprint: EvaluatedFootprint, intent: PlanIntent, engineVersion: String, osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) -> Plan {
        
        var steps = [Step]()
        var excludedItems = [ExcludedItem]()
        var expectedTotalBytes: Int64 = 0
        var index = 0
        
        let fm = FileManager.default
        
        for item in evaluatedFootprint.items {
            let targetURL = item.footprintItem.evidence.url
            let targetPath = targetURL.path
            
            switch item.selection {
            case .selected:
                // Generate step
                let kind: StepKind = .trashPath
                
                // Capture fingerprint for TOCTOU protection
                var fingerprint: TargetFingerprint? = nil
                if let attrs = try? fm.attributesOfItem(atPath: targetPath),
                   let dev = attrs[.systemNumber] as? Int32,
                   let ino = attrs[.systemFileNumber] as? UInt64,
                   let mtime = attrs[.modificationDate] as? Date {
                    fingerprint = TargetFingerprint(dev: dev, ino: ino, mtime: mtime)
                }
                
                let sizeBytes = item.footprintItem.sizeBytes
                expectedTotalBytes += sizeBytes
                
                let phase: ExecutionPhase = (targetPath.hasSuffix(".app") || targetPath.hasSuffix(".app/")) ? .appBundle : .auxiliary
                let step = Step(
                    index: index,
                    kind: kind,
                    target: targetPath,
                    targetFingerprint: fingerprint,
                    tier: item.footprintItem.evidence.tier,
                    evidence: item.footprintItem.evidence.humanSentence,
                    expectedBytes: sizeBytes,
                    capability: item.footprintItem.capability,
                    reversible: true,
                    costOfError: item.costOfError,
                    executionPhase: phase
                )
                
                steps.append(step)
                index += 1
                
            case .unselected:
                // An unselected item isn't strictly excluded by the safety engine,
                // but the user/default didn't select it.
                excludedItems.append(ExcludedItem(target: targetPath, reason: "Unselected by tier defaults or user choice."))
                
            case .excluded(let reason):
                excludedItems.append(ExcludedItem(target: targetPath, reason: reason))
            }
        }
        
        return Plan(
            planId: UUID(),
            createdAt: Date(),
            engineVersion: engineVersion,
            osVersion: osVersion,
            intent: intent,
            steps: steps,
            excludedItems: excludedItems,
            expectedTotalBytes: expectedTotalBytes
        )
    }
}
