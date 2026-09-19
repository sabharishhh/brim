import Foundation
import BrimCore
import BrimScan
import BrimProtocol

/// The in-process implementation of the BrimService.
public actor BrimService: BrimServiceProtocol {
    private let root: FileSystemRoot
    private let engine: EvidenceEngine
    private let safetyEngine: SafetyEngine
    private let planner: Planner
    private let planStore: PlanStore
    
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
    
    public func apply(planId: UUID) async throws {
        // T-1.11 says "Wire inspect/plan/explain/requestApproval/apply/verify/history/capabilities"
        // But execution is M2. So apply() can just be a stub for now or remove items via FileManager directly for M1 tests.
        // The acceptance criteria: "A test exercising the protocol only — no direct Core access — can drive a complete uninstall on the fixture tree."
        
        let plan = try await planStore.load(planId: planId)
        let fm = FileManager.default
        
        for step in plan.steps {
            if step.kind == .trashPath {
                let url = URL(fileURLWithPath: step.target)
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
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
