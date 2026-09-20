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
        
        // T-1.14: "The app bundle is trashed last so a partially blocked run can be retried."
        // We separate app bundle from others based on the footprint capability or tier?
        // Actually, we can check if the target has ".app" or sort by a specific heuristic.
        // It's safer to sort steps: non-app first, app last.
        let sortedSteps = plan.steps.sorted { a, b in
            let aIsApp = a.target.hasSuffix(".app") || a.target.hasSuffix(".app/")
            let bIsApp = b.target.hasSuffix(".app") || b.target.hasSuffix(".app/")
            
            if aIsApp && !bIsApp {
                return false // b comes first
            } else if !aIsApp && bIsApp {
                return true // a comes first
            }
            return a.index < b.index
        }
        
        var hasFailures = false
        
        for step in sortedSteps {
            let isApp = step.target.hasSuffix(".app") || step.target.hasSuffix(".app/")
            if hasFailures && isApp {
                journal.stepOutcomes[step.index] = "skipped_due_to_prior_failures"
                continue
            }
            
            if !fm.fileExists(atPath: step.target) {
                journal.stepOutcomes[step.index] = "already_gone"
                continue
            }
            
            do {
                if step.kind == .trashPath {
                    if let fp = step.targetFingerprint {
                        try SafeOps.trashItem(targetPath: step.target, expectedDev: fp.dev, expectedIno: fp.ino)
                    } else {
                        let url = URL(fileURLWithPath: step.target)
                        var resultingURL: NSURL? = nil
                        try fm.trashItem(at: url, resultingItemURL: &resultingURL)
                    }
                    journal.stepOutcomes[step.index] = "ok"
                } else {
                    journal.stepOutcomes[step.index] = "unsupported_kind"
                    hasFailures = true
                }
            } catch {
                journal.stepOutcomes[step.index] = error.localizedDescription
                hasFailures = true
            }
            
            // Record after each step to handle crashes mid-way
            try await journalStore.write(entry: journal)
        }
        
        let freeAfter = try? SafeOps.freeSpace(onPath: rootPath)
        journal.freeSpaceAfter = freeAfter
        journal.status = hasFailures ? .partial : .completed
        try await journalStore.write(entry: journal)
        
        return journal
    }
}
