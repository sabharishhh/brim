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
    
    public init(root: FileSystemRoot, brimAppURL: URL, planStoreDirectory: URL) {
        self.root = root
        
        self.engine = EvidenceEngine(sources: [
            // AppBundleSource requires the bundleURL, which we don't have universally inside the engine without passing it.
            // Wait, we need the bundleURL for AppBundleSource, but EvidenceEngine only takes Identity and FileSystemRoot.
            // Oh right, Identity doesn't have bundleURL, only name and bundleID.
            // So we use BundleIdentifierComponentSource for app matching, or we add AppBundleSource using a URL if provided.
            // I'll leave AppBundleSource out of the static engine sources for now, or use BundleIdentifierComponentSource to find the app.
            SandboxContainerSource(),
            InstallerReceiptSource(),
            BundleIdentifierComponentSource()
        ])
        
        let checker = SafetyChecker(root: root, brimAppURL: brimAppURL)
        self.safetyEngine = SafetyEngine(safetyChecker: checker)
        self.planner = Planner()
        self.planStore = PlanStore(directoryURL: planStoreDirectory)
        self.tokenStore = TokenStore()
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
        
        let fm = FileManager.default
        
        for step in plan.steps {
            if step.kind == .trashPath {
                let url = URL(fileURLWithPath: step.target)
                if fm.fileExists(atPath: url.path) {
                    if let fp = step.targetFingerprint {
                        try SafeOps.trashItem(targetPath: step.target, expectedDev: fp.dev, expectedIno: fp.ino)
                    } else {
                        // Fallback only if no fingerprint
                        var resultingURL: NSURL? = nil
                        try fm.trashItem(at: url, resultingItemURL: &resultingURL)
                    }
                }
            }
        }
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
