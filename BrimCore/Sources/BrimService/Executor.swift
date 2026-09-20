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
        let uniqueVolumes = Set(plan.steps.map { URL(fileURLWithPath: $0.target).deletingLastPathComponent().path })
        var totalFreeBefore: Int64 = 0
        for vol in uniqueVolumes {
            if let free = try? SafeOps.freeSpace(onPath: vol) { totalFreeBefore += free }
        }
        let freeBefore: Int64? = totalFreeBefore > 0 ? totalFreeBefore : (try? SafeOps.freeSpace(onPath: rootPath))
        
        // Create initial journal
        var journal = JournalEntry(planId: plan.planId, startedAt: Date(), status: .pending, freeSpaceBefore: freeBefore)
        try await journalStore.write(entry: journal)
        
        // Sort by executionPhase, breaking ties by index
        let sortedSteps = plan.steps.sorted { a, b in
            if a.executionPhase != b.executionPhase {
                return a.executionPhase < b.executionPhase
            }
            return a.index < b.index
        }
        
        var hasFailures = false
        
        for step in sortedSteps {
            if hasFailures && step.executionPhase == .appBundle {
                journal.stepOutcomes[step.index] = "skipped_due_to_prior_failures"
                continue
            }
            
            if !fm.fileExists(atPath: step.target) {
                journal.stepOutcomes[step.index] = "already_gone"
                continue
            }
            
            do {
                if step.kind == .trashPath || step.kind == .trashPathPrivileged || step.kind == .removeLaunchdPlist {
                    let resultingURL: URL?
                    if let fp = step.targetFingerprint {
                        resultingURL = try SafeOps.trashItem(targetPath: step.target, expectedDev: fp.dev, expectedIno: fp.ino)
                    } else {
                        throw NSError(domain: "BrimSecurity", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing target fingerprint for secure deletion"])
                    }
                    if let url = resultingURL {
                        if journal.stepTrashedURLs == nil { journal.stepTrashedURLs = [:] }
                        journal.stepTrashedURLs?[step.index] = url
                    }
                    journal.stepOutcomes[step.index] = "ok"
                } else if step.kind == .unloadLaunchdJob {
                    try SafeOps.unloadLaunchdJob(path: step.target)
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
        for vol in uniqueVolumes {
            if let free = try? SafeOps.freeSpace(onPath: vol) { totalFreeAfter += free }
        }
        let freeAfter: Int64? = totalFreeAfter > 0 ? totalFreeAfter : (try? SafeOps.freeSpace(onPath: rootPath))
        journal.freeSpaceAfter = freeAfter
        journal.status = hasFailures ? .partial : .completed
        try await journalStore.write(entry: journal)
        
        return journal
    }
}
