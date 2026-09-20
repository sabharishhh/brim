import Foundation
import BrimCore
import BrimScan
import BrimProtocol
import BrimOps

/// The in-process implementation of the BrimService.
public actor BrimService: BrimServiceProtocol {
    private let root: FileSystemRoot
    private let engine: EvidenceEngine
    private let safetyEngine: SafetyEngine
    private let planner: Planner
    private let planStore: PlanStore
    private let tokenStore: TokenStore
    private let journalStore: JournalStore
    private let executor: Executor
    
    public init(root: FileSystemRoot, brimAppURL: URL, planStoreDirectory: URL, journalStoreDirectory: URL) {
        self.root = root
        
        self.engine = EvidenceEngine(sources: [
            SandboxContainerSource(),
            InstallerReceiptSource(),
            BundleIdentifierComponentSource()
        ])
        
        let checker = SafetyChecker(root: root, brimAppURL: brimAppURL)
        self.safetyEngine = SafetyEngine(safetyChecker: checker)
        self.planner = Planner()
        self.planStore = PlanStore(directoryURL: planStoreDirectory)
        self.tokenStore = TokenStore()
        
        self.journalStore = JournalStore(directoryURL: journalStoreDirectory)
        self.executor = Executor(journalStore: self.journalStore)
    }
    
    public func inspect(identity: Identity) async throws -> Footprint {
        let projector = FootprintProjector(engine: engine)
        return try await projector.project(identity: identity, in: root)
    }
    
    public func plan(intent: PlanIntent) async throws -> Plan {
        let footprint = try await inspect(identity: intent.subjectIdentity)
        let evaluated = safetyEngine.evaluate(footprint: footprint)
        let plan = planner.createPlan(from: evaluated, intent: intent, engineVersion: EvidenceEngineRevision)
        try await planStore.save(plan: plan)
        return plan
    }
    
    public func explain(planId: UUID) async throws -> String {
        let plan = try await planStore.load(planId: planId)
        return "Plan \(plan.planId) targets \(plan.steps.count) items taking \(plan.expectedTotalBytes) bytes."
    }
    
    public func requestApproval(planId: UUID, requesterIdentity: String) async throws {
        let plan = try await planStore.load(planId: planId)
        // In a real app, this would post a Notification or callback to the UI,
        // and the UI would call `TokenStore.mintToken()` upon user approval.
        // For testing, we just simulate the recording.
        print("Approval requested for plan \(plan.planId) by \(requesterIdentity)")
    }
    
    // Test helper to allow tests to mint tokens since the TokenStore is private
    // and no protocol API exposes it.
    public func mintTokenForTest(planId: UUID, planHash: String, requesterIdentity: String) async -> ApprovalToken {
        return await tokenStore.mintToken(planId: planId, planHash: planHash, requesterIdentity: requesterIdentity)
    }
    
    public func apply(planId: UUID, token: ApprovalToken) async throws {
        let plan = try await planStore.load(planId: planId)
        let hash = try plan.contentHash()
        
        try await tokenStore.consumeAndValidate(
            token: token,
            expectedPlanId: plan.planId,
            expectedPlanHash: hash,
            expectedRequesterIdentity: plan.intent.requesterIdentity
        )
        
        _ = try await executor.execute(plan: plan)
    }
    
    public func verify(planId: UUID) async throws -> VerificationResult {
        let plan = try await planStore.load(planId: planId)
        
        let journal = try? await journalStore.load(planId: planId)
        let before = journal?.freeSpaceBefore ?? 0
        let after = journal?.freeSpaceAfter ?? 0
        let recoveredBytes = max(0, after - before)
        
        // Re-observe targets
        let fm = FileManager.default
        var targetsRemaining = 0
        for step in plan.steps {
            if fm.fileExists(atPath: step.target) {
                // Was it excluded?
                if journal?.stepOutcomes[step.index] == "skipped_due_to_prior_failures" {
                    continue
                }
                targetsRemaining += 1
            }
        }
        
        let success = targetsRemaining == 0
        let reason = success ? nil : "\(targetsRemaining) targets still remain."
        
        return VerificationResult(
            planId: planId,
            expectedBytes: plan.expectedTotalBytes,
            recoveredBytes: recoveredBytes,
            success: success,
            reason: reason
        )
    }
    
    public func history() async throws -> [Plan] {
        // Return all completed or partially completed plans from the journal store
        let planIds = try await journalStore.allPlanIds()
        var plans: [Plan] = []
        for id in planIds {
            if let journal = try? await journalStore.load(planId: id),
               journal.status == .completed || journal.status == .partial {
                if let plan = try? await planStore.load(planId: id) {
                    plans.append(plan)
                }
            }
        }
        return plans
    }
    
    public func undo(planId: UUID) async throws {
        let plan = try await planStore.load(planId: planId)
        guard let journal = try await journalStore.load(planId: planId) else {
            throw NSError(domain: "BrimService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No journal found for plan."])
        }
        let trashedURLs = journal.stepTrashedURLs ?? [:]
        
        let fm = FileManager.default
        
        // 1. Check if ANY path is re-occupied before moving things back
        for step in plan.steps {
            if trashedURLs[step.index] != nil {
                if fm.fileExists(atPath: step.target) {
                    throw NSError(domain: "BrimService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path \(step.target) has been re-occupied."])
                }
            }
        }
        
        // 2. Restore items from Trash
        for step in plan.steps {
            if let trashedURL = trashedURLs[step.index] {
                let targetURL = URL(fileURLWithPath: step.target)
                // We MUST ensure the parent directory exists
                let parentURL = targetURL.deletingLastPathComponent()
                if !fm.fileExists(atPath: parentURL.path) {
                    try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
                }
                
                try fm.moveItem(at: trashedURL, to: targetURL)
            }
        }
        
        // 3. Update journal to mark undone? Or just delete journal?
        try await journalStore.delete(planId: planId)
    }
}
