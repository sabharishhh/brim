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
    
    public func verify(planId: UUID) async throws -> Bool {
        let plan = try await planStore.load(planId: planId)
        let fm = FileManager.default
        
        for step in plan.steps {
            if step.kind == .trashPath {
                let url = URL(fileURLWithPath: step.target)
                if fm.fileExists(atPath: url.path) {
                    return false // Still exists!
                }
            }
        }
        return true
    }
    
    public func history() async throws -> [Plan] {
        // Just a stub for M1
        return []
    }
}
