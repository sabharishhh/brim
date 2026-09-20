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
        
        var evaluatedItems = evaluatedFootprint.items
        
        // Handle reset specific filtering
        if intent.type == .reset {
            let footprint = Footprint(identity: intent.subjectIdentity, items: evaluatedFootprint.items.map { $0.footprintItem })
            let (toDelete, toExclude) = ResetFilter.filter(footprint: footprint)
            
            // Re-evaluate selections based on ResetFilter
            var newEvaluatedItems = [EvaluatedItem]()
            for item in evaluatedFootprint.items {
                if let excluded = toExclude.first(where: { $0.target == item.footprintItem.evidence.url.path }) {
                    newEvaluatedItems.append(EvaluatedItem(footprintItem: item.footprintItem, selection: .excluded(reason: excluded.reason), costOfError: item.costOfError))
                } else if toDelete.contains(where: { $0.evidence.url.path == item.footprintItem.evidence.url.path }) {
                    // Only select if it was previously selected (or at least not excluded for a harder reason like Safety)
                    if case .selected = item.selection {
                        newEvaluatedItems.append(item)
                    } else if case .unselected = item.selection {
                         // Reset implies we want to trash state, so if it was merely unselected by default, select it
                         newEvaluatedItems.append(EvaluatedItem(footprintItem: item.footprintItem, selection: .selected, costOfError: item.costOfError))
                    } else {
                         // Preserve safety exclusions
                         newEvaluatedItems.append(item)
                    }
                } else {
                    newEvaluatedItems.append(item)
                }
            }
            evaluatedItems = newEvaluatedItems
        }
        
        // One reset for the whole plan, before anything is removed. Placed
        // first because tccutil needs the bundle to still exist; an uninstall
        // that deletes first leaves the grants stranded for good, which is
        // how stale accessibility entries accumulate.
        // Only when uninstalling the whole application. A plan for specific
        // targets — one leftover picked out of the queue — must not clear an
        // app's accessibility or screen-recording permissions as a side
        // effect of tidying a cache directory.
        if intent.type == .uninstall,
           intent.explicitTargets.isEmpty,
           let bundleID = intent.subjectIdentity.bundleID {
            steps.append(Step(
                index: index,
                kind: .resetPrivacyGrants,
                target: bundleID,
                targetFingerprint: nil,
                tier: .A,
                evidence: "Clears the privacy permissions macOS holds for this application, such as "
                        + "accessibility, screen recording and full disk access.",
                expectedBytes: 0,
                capability: .ok,
                reversible: false,
                costOfError: .medium,
                executionPhase: .privacyReset,
                disposition: .delete
            ))
            index += 1
        }

        for item in evaluatedItems {
            let targetURL = item.footprintItem.evidence.url
            let targetPath = targetURL.path
            
            switch item.selection {
            case .selected:
                // Generate step
                
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

                // A recreatable cache is deleted outright so the space really
                // comes back; anything holding settings or user data goes to
                // the Trash so undo can reach it.
                let disposition = StepDisposition.default(for: item.costOfError)
                let isReversible = disposition == .trash
                
                if intent.type == .archive, let dest = intent.destinationTarget {
                    let archiveStep = Step(
                        index: index,
                        kind: .archivePath,
                        target: targetPath,
                        targetFingerprint: fingerprint,
                        tier: item.footprintItem.evidence.tier,
                        evidence: ExplanationRenderer().render(tier: item.footprintItem.evidence.tier, capability: item.footprintItem.capability, mechanism: item.footprintItem.evidence.mechanism),
                        expectedBytes: sizeBytes,
                        capability: item.footprintItem.capability,
                        reversible: true,
                        costOfError: item.costOfError,
                        executionPhase: .archive,
                        archiveDestination: dest.path
                    )
                    steps.append(archiveStep)
                    index += 1
                }
                
                // Only generate destructive steps if intent is NOT archive, OR if archive explicitly requested uninstall
                let shouldDelete = (intent.type != .archive) || (intent.type == .archive && intent.archiveAndUninstall)
                
                if shouldDelete {
                    if item.footprintItem.evidence.mechanism == "LaunchdSource" {
                        let unloadStep = Step(
                            index: index,
                            kind: .unloadLaunchdJob,
                            target: targetPath,
                            targetFingerprint: fingerprint,
                            tier: item.footprintItem.evidence.tier,
                            evidence: ExplanationRenderer().render(tier: item.footprintItem.evidence.tier, capability: item.footprintItem.capability, mechanism: item.footprintItem.evidence.mechanism),
                            expectedBytes: 0,
                            capability: item.footprintItem.capability,
                            reversible: true,
                            costOfError: item.costOfError,
                            executionPhase: .launchd
                        )
                        steps.append(unloadStep)
                        index += 1
                        
                        let removeStep = Step(
                            index: index,
                            kind: .removeLaunchdPlist,
                            target: targetPath,
                            targetFingerprint: fingerprint,
                            tier: item.footprintItem.evidence.tier,
                            evidence: ExplanationRenderer().render(tier: item.footprintItem.evidence.tier, capability: item.footprintItem.capability, mechanism: item.footprintItem.evidence.mechanism),
                            expectedBytes: sizeBytes,
                            capability: item.footprintItem.capability,
                            reversible: isReversible,
                            costOfError: item.costOfError,
                            executionPhase: .launchd,
                            disposition: disposition
                        )
                        steps.append(removeStep)
                        index += 1
                    } else {
                        let step = Step(
                            index: index,
                            kind: .trashPath,
                            target: targetPath,
                            targetFingerprint: fingerprint,
                            tier: item.footprintItem.evidence.tier,
                            evidence: ExplanationRenderer().render(tier: item.footprintItem.evidence.tier, capability: item.footprintItem.capability, mechanism: item.footprintItem.evidence.mechanism),
                            expectedBytes: sizeBytes,
                            capability: item.footprintItem.capability,
                            reversible: isReversible,
                            costOfError: item.costOfError,
                            executionPhase: phase,
                            disposition: disposition
                        )
                        steps.append(step)
                        index += 1
                    }
                }
            case .unselected:
                excludedItems.append(ExcludedItem(target: targetPath, reason: "You opted to keep this item, or it was unselected by default due to low confidence."))
                
            case .excluded(let reason):
                excludedItems.append(ExcludedItem(target: targetPath, reason: ExplanationRenderer().renderRefusal(reason: reason)))
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
