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
        let rootPath = plan.steps.first?.target ?? "/"
        let freeBefore = try? SafeOps.freeSpace(onPath: rootPath)
        
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
                if step.kind == .trashPath || step.kind == .removeLaunchdPlist {
                    let resultingURL: URL?
                    if let fp = step.targetFingerprint {
                        resultingURL = try SafeOps.trashItem(targetPath: step.target, expectedDev: fp.dev, expectedIno: fp.ino)
                    } else {
                        let url = URL(fileURLWithPath: step.target)
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        resultingURL = nil
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
            } catch {
                journal.stepOutcomes[step.index] = error.localizedDescription
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
        
        let freeAfter = try? SafeOps.freeSpace(onPath: rootPath)
        journal.freeSpaceAfter = freeAfter
        journal.status = hasFailures ? .partial : .completed
        try await journalStore.write(entry: journal)
        
        return journal
    }
}
