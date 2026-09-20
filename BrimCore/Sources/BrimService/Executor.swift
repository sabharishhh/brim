import Foundation
import BrimCore
import BrimOps

public actor Executor {
    private let journalStore: JournalStore
    private let fm = FileManager.default
    
    public init(journalStore: JournalStore) {
        self.journalStore = journalStore
    }
    
    public func execute(plan: Plan) async throws -> JournalEntry {
        let rootPath = plan.steps.first?.target ?? "/" // fallback
        // M3: Collect unique volume paths and sum their free space
        var volumeSet = Set<String>()
        for step in plan.steps {
            var statBuf = statfs()
            if statfs(step.target, &statBuf) == 0 {
                let mntonname = withUnsafePointer(to: statBuf.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { ptr in String(cString: ptr) }
                }
                volumeSet.insert(mntonname)
            } else if statfs(URL(fileURLWithPath: step.target).deletingLastPathComponent().path, &statBuf) == 0 {
                let mntonname = withUnsafePointer(to: statBuf.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { ptr in String(cString: ptr) }
                }
                volumeSet.insert(mntonname)
            }
        }
        
        var totalFreeBefore: Int64 = 0
        for vol in volumeSet {
            if let free = try? SafeOps.freeSpace(onPath: vol) { totalFreeBefore += free }
        }
        let freeBefore: Int64? = totalFreeBefore > 0 ? totalFreeBefore : (try? SafeOps.freeSpace(onPath: rootPath))
        
        // Create initial journal
        var journal = JournalEntry(planId: plan.planId, startedAt: Date(), status: .pending, freeSpaceBefore: freeBefore)
        try await journalStore.write(entry: journal)
        
        let sortedSteps = plan.executionOrderedSteps
        
        var hasFailures = false
        
        for step in sortedSteps {
            if hasFailures {
                let hadArchiveFailure = sortedSteps.contains { s in s.kind == .archivePath && journal.stepOutcomes[s.index] != nil && journal.stepOutcomes[s.index] != "ok" }
                if hadArchiveFailure {
                    journal.stepOutcomes[step.index] = "skipped_due_to_prior_failures"
                    continue
                }
                if step.executionPhase == .appBundle {
                    journal.stepOutcomes[step.index] = "skipped_due_to_prior_failures"
                    continue
                }
            }
            
            // Steps whose target is an identifier rather than a path are
            // not subject to the "already gone" check; a bundle id is not a
            // file, and skipping it here would silently drop the reset.
            if step.kind != .resetPrivacyGrants, !fm.fileExists(atPath: step.target) {
                journal.stepOutcomes[step.index] = "already_gone"
                continue
            }
            
            do {
                if step.kind == .trashPath || step.kind == .trashPathPrivileged || step.kind == .removeLaunchdPlist {
                    guard let fp = step.targetFingerprint else {
                        throw NSError(domain: "BrimSecurity", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing target fingerprint for secure deletion"])
                    }

                    switch step.effectiveDisposition {
                    case .trash:
                        let resultingURL = try SafeOps.trashItem(targetPath: step.target, expectedDev: fp.dev, expectedIno: fp.ino)
                        if let url = resultingURL {
                            if journal.stepTrashedURLs == nil { journal.stepTrashedURLs = [:] }
                            journal.stepTrashedURLs?[step.index] = url
                        }
                    case .delete:
                        // Permanent: no trashed URL is recorded, so undo knows
                        // there is nothing to put back for this step.
                        try SafeOps.deleteItem(targetPath: step.target, expectedDev: fp.dev, expectedIno: fp.ino)
                    }
                    journal.stepOutcomes[step.index] = "ok"
                } else if step.kind == .resetPrivacyGrants {
                    // Must run while the bundle is still on disk; the plan's
                    // privacyReset phase sorts ahead of every removal so that
                    // holds. The target is a bundle identifier, not a path.
                    //
                    // Recorded but never fatal: the user asked for the app to
                    // be removed, and refusing to remove it because a grant
                    // could not be cleared would be the wrong trade. The
                    // outcome is journalled so the result can say so.
                    do {
                        try PrivacyGrants.resetAll(bundleID: step.target)
                        journal.stepOutcomes[step.index] = "ok"
                    } catch {
                        journal.stepOutcomes[step.index] = "privacy_grants_not_cleared: \(error.localizedDescription)"
                    }
                } else if step.kind == .unloadLaunchdJob {
                    try SafeOps.unloadLaunchdJob(path: step.target)
                    journal.stepOutcomes[step.index] = "ok"
                } else if step.kind == .archivePath, let dest = step.archiveDestination {
                    guard let fp = step.targetFingerprint else {
                        throw NSError(domain: "BrimSecurity", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing target fingerprint for secure archive"])
                    }
                    // Validate planned target identity before copying (TOCTOU protection)
                    try SafeOps.verifyTargetFingerprint(targetPath: step.target, expectedDev: fp.dev, expectedIno: fp.ino)
                    
                    let destURL = URL(fileURLWithPath: dest)
                    // Preserve relative directory hierarchy (e.g. "/Applications/App.app" -> "destURL/Applications/App.app")
                    let relPath = step.target.hasPrefix("/") ? String(step.target.dropFirst()) : step.target
                    let itemDestURL = destURL.appendingPathComponent(relPath)
                    
                    try fm.createDirectory(at: itemDestURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                    
                    if fm.fileExists(atPath: itemDestURL.path) {
                        try fm.removeItem(at: itemDestURL)
                    }
                    try fm.copyItem(atPath: step.target, toPath: itemDestURL.path)
                    
                    journal.stepOutcomes[step.index] = "ok"
                } else {
                    journal.stepOutcomes[step.index] = "unsupported_kind"
                    hasFailures = true
                }
            } catch let SafeOpsError.failedToRename(err) where err == EPERM {
                journal.stepOutcomes[step.index] = "refusedByOS"
                hasFailures = true
            } catch let SafeOpsError.failedToUnlink(err) where err == EPERM {
                journal.stepOutcomes[step.index] = "refusedByOS"
                hasFailures = true
            } catch {
                let nsErr = error as NSError
                if (nsErr.domain == NSCocoaErrorDomain && nsErr.code == 513) || nsErr.code == EPERM || (nsErr.domain == NSPOSIXErrorDomain && nsErr.code == EPERM) {
                    journal.stepOutcomes[step.index] = "refusedByOS"
                } else {
                    journal.stepOutcomes[step.index] = error.localizedDescription
                }
                hasFailures = true
            }
            
            // Record after each step to handle crashes mid-way. 
            // AUDIT H-6 FIX: Swallow write errors to avoid aborting execution.
            do {
                try await journalStore.write(entry: journal)
            } catch {
                print("Warning: Failed to write journal entry for step \(step.index): \(error)")
            }
        }
        
        var totalFreeAfter: Int64 = 0
        for vol in volumeSet {
            if let free = try? SafeOps.freeSpace(onPath: vol) { totalFreeAfter += free }
        }
        let freeAfter: Int64? = totalFreeAfter > 0 ? totalFreeAfter : (try? SafeOps.freeSpace(onPath: rootPath))
        journal.freeSpaceAfter = freeAfter
        journal.status = hasFailures ? .partial : .completed
        try await journalStore.write(entry: journal)
        
        return journal
    }
}
