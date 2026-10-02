import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// The system component that generates an executable plan from an evaluated footprint.
public struct Planner: Sendable {
    public init() {}

    public func createPlan(from evaluatedFootprint: EvaluatedFootprint, intent: PlanIntent, engineVersion: String, osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString, capabilityReport: CapabilitySearchReport? = nil, receiptPayloads: [String: [String]] = [:]) -> Plan {
        var steps = [Step]()
        var excludedItems = [ExcludedItem]()
        var expectedTotalBytes: Int64 = 0
        var index = 0

        let fm = FileManager.default

        var evaluatedItems = evaluatedFootprint.items

        // Explicit ticks may promote found rows, but never a shared veto or a new path.
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

        // Reset eligible identifiers before their code leaves; preserve shared grants.
        if intent.type == .uninstall,
           intent.explicitTargets.isEmpty,
           evaluatedFootprint.survivingCopies.isEmpty,
           evaluatedFootprint.completeness.isComplete,
           evaluatedItems.contains(where: {
               $0.selection == .selected && $0.footprintItem.evidence.url.pathExtension == "app"
           }),
           let bundleID = intent.subjectIdentity.bundleID {
            let host = evaluatedFootprint.identity.bundlePath ?? ""
            let componentIDs = evaluatedFootprint.identity.identitySurface?.components
                .compactMap { component -> String? in
                    guard component.path.hasPrefix(host + "/"),
                          ["app", "appex", "xpc"].contains(URL(fileURLWithPath: component.path).pathExtension),
                          PathObservation.observe(component.path).isPresent,
                          let identifier = component.bundleIdentifier,
                          evaluatedFootprint.identity.searchBundleIdentifiers.contains(identifier) else { return nil }
                    return identifier
                } ?? []
            let protected = Set(evaluatedFootprint.protectedComponentIdentifiers)
            for resetID in Set([bundleID] + componentIDs).subtracting(protected).sorted() {
                steps.append(Step(
                    index: index,
                    kind: .resetPrivacyGrants,
                    target: resetID,
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
        }

        // Nested paths leave with the selected containing bundle.
        let removedWhole: [String] = evaluatedItems.compactMap { item in
            guard case .selected = item.selection else { return nil }
            let path = item.footprintItem.evidence.url.standardizedFileURL.path
            let helperOnly = item.footprintItem.capability == .needsHelper
            return helperOnly && !HelperScope.covers(path) ? nil : path
        }

        var plannedPaths = Set<String>()
        for item in evaluatedItems {
            let targetURL = item.footprintItem.evidence.url
            let targetPath = targetURL.path
            let standardized = targetURL.standardizedFileURL.path
            if removedWhole.contains(where: { standardized.hasPrefix($0 + "/") }) {
                continue
            }
            // Shown with the reason it stays whatever its tier, and never
            // offered for ticking: nothing Brim may do would remove it.
            if HelperScope.signInFolders.contains(targetURL.deletingLastPathComponent().path),
               let kept = HelperScope.keptOut(targetPath, bytes: item.footprintItem.sizeBytes) {
                excludedItems.append(kept)
                continue
            }

            switch item.selection {
            case .selected:
                guard plannedPaths.insert(standardized).inserted else { continue }
                // A receipt is forgotten below, which removes its files
                // with it. Trashing the BOM as well offered a second row
                // for one record, and one that belongs to root.
                if item.footprintItem.evidence.mechanism == "InstallerReceiptSource",
                   intent.type == .uninstall, intent.explicitTargets.isEmpty {
                    continue
                }

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

                let phase: ExecutionPhase = (targetPath.hasSuffix(".app") || targetPath.hasSuffix(".app/")) ?
                    .appBundle : .auxiliary

                // A recreatable cache is deleted outright so the space really
                // comes back; anything holding settings or user data goes to
                // the Trash so undo can reach it.
                let disposition = StepDisposition.default(for: item.costOfError)
                let isReversible = disposition == .trash

                // Root's folders need the daemon, decided here so one selection
                // can mix the person's files with root's in one plan and one
                // review. Only what the daemon will take becomes a step; the
                // rest stays out with its reason. See `HelperScope.keptOut`.
                let needsPrivilege = item.footprintItem.capability == .needsHelper
                if needsPrivilege, let kept = HelperScope.keptOut(targetPath, bytes: sizeBytes) {
                    expectedTotalBytes -= sizeBytes
                    excludedItems.append(kept)
                    continue
                }

                // A locked file used to disappear from the plan: the safety
                // checker refused it and said nothing, so the person saw a
                // shorter list instead of a reason. Unlocking is now a step
                // of its own, placed before the removal it exists to let
                // through, and the review sheet shows it.
                if let lock = ArtifactLock.on(path: targetPath) {
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

                if needsPrivilege {
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
                            ? .launchd : phase,
                        disposition: .trash
                    ))
                    index += 1
                } else {
                    if item.footprintItem.evidence.mechanism == "LaunchdSource" {
                        let unloadStep = Step(
                            index: index,
                            kind: .unloadLaunchdJob,
                            target: targetPath,
                            targetFingerprint: fingerprint,
                            tier: item.footprintItem.evidence.tier,
                            evidence: ExplanationRenderer().render(
                                tier: item.footprintItem.evidence.tier,
                                capability: item.footprintItem.capability,
                                mechanism: item.footprintItem.evidence.mechanism,
                                found: item.footprintItem.evidence.humanSentence
                            ),
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
                            evidence: ExplanationRenderer().render(
                                tier: item.footprintItem.evidence.tier,
                                capability: item.footprintItem.capability,
                                mechanism: item.footprintItem.evidence.mechanism,
                                found: item.footprintItem.evidence.humanSentence
                            ),
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
                            evidence: ExplanationRenderer().render(
                                tier: item.footprintItem.evidence.tier,
                                capability: item.footprintItem.capability,
                                mechanism: item.footprintItem.evidence.mechanism,
                                found: item.footprintItem.evidence.humanSentence
                            ),
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

            case let .excluded(reason):
                excludedItems.append(ExcludedItem(
                    target: targetPath,
                    reason: ExplanationRenderer().renderRefusal(reason: reason),
                    sizeBytes: item.footprintItem.sizeBytes,
                    canBeTickedByHand: false
                ))
            }
        }

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
                guard evaluatedFootprint.completeness.isComplete,
                      let payload = receiptPayloads[packageID], !payload.isEmpty
                else {
                    excludedItems.append(ExcludedItem(
                        target: item.footprintItem.evidence.url.path,
                        reason: "The installer record is kept because its complete payload could not be checked.",
                        canBeTickedByHand: false
                    ))
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
                executionPhase: .privacyReset
            ))
            index += 1
        }

        if intent.type == .uninstall,
           intent.explicitTargets.isEmpty,
           capabilityReport?.checks.first(where: { $0.capability == .launchServices })?.coverage.absence != .byDesign,
           let bundleStep = steps.first(where: { $0.executionPhase == .appBundle }) {
            let host = bundleStep.target
            let registered = capabilityReport?.checks
                .first { $0.capability == .launchServices }?.registrations.compactMap(\.programPath) ?? []
            let components = intent.subjectIdentity.identitySurface?.components.map(\.path) ?? []
            let paths = Set([host] + (registered + components).filter {
                $0.hasPrefix(host + "/") && $0.hasSuffix(".app")
            })
            for registrationPath in paths.sorted() {
                steps.append(Step(
                    index: index,
                    kind: .unregisterLaunchServices,
                    target: registrationPath,
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
        }

        return Plan(
            planId: UUID(),
            createdAt: Date(),
            engineVersion: engineVersion,
            osVersion: osVersion,
            intent: PlanIntent(type: intent.type, subjectIdentity: evaluatedFootprint.identity,
                               requesterKind: intent.requesterKind, requesterIdentity: intent.requesterIdentity,
                               specificTarget: intent.specificTarget, specificTargets: intent.specificTargets,
                               tickedByHand: intent.tickedByHand, toolCleanup: intent.toolCleanup,
                               excludedFolders: intent.excludedFolders),
            steps: steps,
            excludedItems: excludedItems,
            expectedTotalBytes: expectedTotalBytes,
            scanCompleteness: evaluatedFootprint.completeness,
            survivingCopies: evaluatedFootprint.survivingCopies,
            protectedComponentIdentifiers: evaluatedFootprint.protectedComponentIdentifiers,
            receiptPayloads: receiptPayloads
        )
    }
}
