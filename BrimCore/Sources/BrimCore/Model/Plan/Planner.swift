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

        // Rows the person ticked in the uninstall sheet. Brim left them
        // unticked because it was not sure enough to remove them unasked,
        // which is not the same as not being allowed to remove them: every
        // row can still be ticked by hand.
        //
        // Only a row the evidence engine found and left unselected can be
        // promoted. A path the engine did not find is not in this list to
        // promote, so naming one adds nothing, and an uninstall stays an
        // uninstall rather than becoming a way to remove anything at all. A
        // vetoed row is `.excluded` and is left alone, which is how Tier S
        // stays one way: something else on this Mac claims it, and no list
        // brings it back.
        if let ticked = intent.tickedByHand, !ticked.isEmpty {
            let wanted = Set(ticked)
            evaluatedItems = evaluatedItems.map { item in
                guard case .unselected = item.selection,
                      wanted.contains(item.footprintItem.evidence.url.path)
                else { return item }
                return EvaluatedItem(
                    footprintItem: item.footprintItem, selection: .selected,
                    costOfError: item.costOfError
                )
            }
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
                        evidence: ExplanationRenderer().render(tier: item.footprintItem.evidence.tier, capability: item.footprintItem.capability, mechanism: item.footprintItem.evidence.mechanism, found: item.footprintItem.evidence.humanSentence),
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
                
                // A target in a folder that belongs to root needs the
                // daemon, whatever kind of thing it is. Deciding this here
                // rather than at the point of failure is what lets one
                // selection mix a file of the user's with one of root's
                // and still be a single plan, a single review and a single
                // confirmation. Whose folder something sits in is not a
                // distinction a person should have to make.
                let needsPrivilege = item.footprintItem.capability == .needsHelper

                // A locked file used to disappear from the plan: the safety
                // checker refused it and said nothing, so the person saw a
                // shorter list instead of a reason. Unlocking is now a step
                // of its own, placed before the removal it exists to let
                // through, and the review sheet shows it.
                if shouldDelete, let lock = ArtifactLock.on(path: targetPath) {
                    if lock.canBeCleared {
                        steps.append(Step(
                            index: index,
                            kind: .clearImmutableFlag,
                            target: targetPath,
                            targetFingerprint: fingerprint,
                            tier: item.footprintItem.evidence.tier,
                            evidence: "This is locked, the way Finder's Get Info panel locks a "
                                    + "file. Brim unlocks it first, or nothing below can move.",
                            expectedBytes: 0,
                            capability: item.footprintItem.capability,
                            reversible: true,
                            costOfError: item.costOfError,
                            executionPhase: .privacyReset
                        ))
                        index += 1
                    } else {
                        excludedItems.append(ExcludedItem(
                            target: targetPath,
                            reason: "macOS has locked this at the system level, not you. "
                                  + "It cannot be unlocked here, and it is almost "
                                  + "always locked for a reason."
                        ))
                        continue
                    }
                }

                if shouldDelete, needsPrivilege {
                    steps.append(Step(
                        index: index,
                        kind: .trashPathPrivileged,
                        target: targetPath,
                        targetFingerprint: fingerprint,
                        tier: item.footprintItem.evidence.tier,
                        evidence: "In a system folder, so the helper "
                                + "sets it aside where an administrator can still reach it.",
                        expectedBytes: sizeBytes,
                        capability: item.footprintItem.capability,
                        reversible: true,
                        costOfError: item.costOfError,
                        executionPhase: item.footprintItem.evidence.mechanism == "LaunchdSource"
                            ? .launchd : .auxiliary,
                        disposition: .trash
                    ))
                    index += 1
                } else if shouldDelete {
                    if item.footprintItem.evidence.mechanism == "LaunchdSource" {
                        let unloadStep = Step(
                            index: index,
                            kind: .unloadLaunchdJob,
                            target: targetPath,
                            targetFingerprint: fingerprint,
                            tier: item.footprintItem.evidence.tier,
                            evidence: ExplanationRenderer().render(tier: item.footprintItem.evidence.tier, capability: item.footprintItem.capability, mechanism: item.footprintItem.evidence.mechanism, found: item.footprintItem.evidence.humanSentence),
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
                            evidence: ExplanationRenderer().render(tier: item.footprintItem.evidence.tier, capability: item.footprintItem.capability, mechanism: item.footprintItem.evidence.mechanism, found: item.footprintItem.evidence.humanSentence),
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
                            evidence: ExplanationRenderer().render(tier: item.footprintItem.evidence.tier, capability: item.footprintItem.capability, mechanism: item.footprintItem.evidence.mechanism, found: item.footprintItem.evidence.humanSentence),
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
                // Described the way a step is, because the sheet offers it
                // beside the steps and a row a person is asked to decide on
                // has to say how Brim found it and what it holds.
                excludedItems.append(ExcludedItem(
                    target: targetPath,
                    reason: "You opted to keep this item, or it was unselected by default due to low confidence.",
                    evidence: ExplanationRenderer().render(
                        tier: item.footprintItem.evidence.tier,
                        capability: item.footprintItem.capability,
                        mechanism: item.footprintItem.evidence.mechanism,
                        found: item.footprintItem.evidence.humanSentence
                    ),
                    sizeBytes: item.footprintItem.sizeBytes,
                    canBeTickedByHand: true,
                    tier: item.footprintItem.evidence.tier
                ))

            case .excluded(let reason):
                excludedItems.append(ExcludedItem(
                    target: targetPath,
                    reason: ExplanationRenderer().renderRefusal(reason: reason),
                    sizeBytes: item.footprintItem.sizeBytes,
                    canBeTickedByHand: false
                ))
            }
        }
        
        // Receipts, after the files they describe. `pkgutil --forget`
        // deletes nothing: it removes the installer's record, so the
        // product stops appearing in `pkgutil --pkgs` and an installer
        // cannot offer to "repair" it back into existence. Irreversible
        // for the same reason it is safe, because a record is all it is.
        if intent.type == .uninstall, intent.explicitTargets.isEmpty {
            var alreadyForgotten = Set<String>()
            for item in evaluatedItems {
                guard case .selected = item.selection,
                      item.footprintItem.evidence.mechanism == "InstallerReceiptSource"
                else { continue }
                let packageID = item.footprintItem.evidence.url
                    .deletingPathExtension().lastPathComponent
                guard !packageID.isEmpty, alreadyForgotten.insert(packageID).inserted else {
                    continue
                }
                steps.append(Step(
                    index: index,
                    kind: .forgetReceipt,
                    target: packageID,
                    targetFingerprint: nil,
                    tier: .A,
                    evidence: "Removes the installer's record of \(packageID). No files are "
                            + "deleted by this, but without it the package keeps showing up "
                            + "as installed.",
                    expectedBytes: 0,
                    capability: .needsHelper,
                    reversible: false,
                    costOfError: .medium,
                    executionPhase: .registration,
                    disposition: .delete
                ))
                index += 1
            }
        }

        // The vendor's own uninstaller, when one ships. Revealed, never
        // run: this is somebody else's executable, and the point of the
        // step is that a person decides. A plan carrying one is incomplete
        // by design and says so.
        if intent.type == .uninstall,
           intent.explicitTargets.isEmpty,
           let bundleStep = steps.first(where: { $0.executionPhase == .appBundle }),
           let found = VendorUninstallerDetector.insideBundle(
               at: URL(fileURLWithPath: bundleStep.target)
           ) {
            steps.append(Step(
                index: index,
                kind: .revealVendorUninstaller,
                target: found.path,
                targetFingerprint: nil,
                tier: .A,
                evidence: found.reason,
                expectedBytes: 0,
                capability: .ok,
                reversible: true,
                costOfError: .low,
                executionPhase: .registration
            ))
            index += 1
        }

        // The last thing to happen, and only for a whole-app uninstall:
        // retract the Launch Services registration for the bundle we just
        // removed. Deleting the bundle does not do this — the record
        // survives, which is why removed apps linger in "Open With" and keep
        // claiming their document types. It has to run after the removal,
        // because Launch Services re-registers a bundle it can still see.
        if intent.type == .uninstall,
           intent.explicitTargets.isEmpty,
           let bundleStep = steps.first(where: { $0.executionPhase == .appBundle }) {
            steps.append(Step(
                index: index,
                kind: .unregisterLaunchServices,
                target: bundleStep.target,
                targetFingerprint: nil,
                tier: .A,
                evidence: "Removes the Launch Services registration, so the app stops appearing in "
                        + "\"Open With\" and no longer claims its document types or URL schemes.",
                expectedBytes: 0,
                capability: .ok,
                reversible: false,
                costOfError: .low,
                executionPhase: .registration,
                disposition: .delete
            ))
            index += 1
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
