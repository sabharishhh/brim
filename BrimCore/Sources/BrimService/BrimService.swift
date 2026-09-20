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
        // Just a stub for M1
        return []
    }
}
