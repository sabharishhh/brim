import Foundation
import BrimCore
import LocalAuthentication
import BrimScan
import BrimProtocol
import BrimOps

/// The in-process implementation of the BrimService.
public actor BrimService: BrimServiceProtocol {
    public let root: FileSystemRoot
    private let engine: EvidenceEngine
    private let safetyEngine: SafetyEngine
    private let planner: Planner
    public let planStore: PlanStore
    public let tokenStore: TokenStore
    private let journalStore: JournalStore
    private let ledgerStore: LedgerStore
    private let executor: Executor
    
    public init(root: FileSystemRoot, brimAppURL: URL, planStoreDirectory: URL, journalStoreDirectory: URL) {
        self.root = root
        
        self.engine = EvidenceEngine(sources: [
            
            AppBundleSource(),
            SandboxContainerSource(),
            InstallerReceiptSource(),
            BundleIdentifierComponentSource(),
            GroupContainerSource(),
            BundleIdentifierStateSource(),
            TeamIDSource(),
            LaunchServicesSource(),
            SMAppServiceSource(),
            LaunchdSource()
        ])
        
        let checker = SafetyChecker(root: root, brimAppURL: brimAppURL)
        let vetoEngine = TierSVetoEngine(root: root)
        self.safetyEngine = SafetyEngine(safetyChecker: checker, vetoEngine: vetoEngine)
        self.planner = Planner()
        self.planStore = PlanStore(directoryURL: planStoreDirectory)
        let tokensDir = planStoreDirectory.deletingLastPathComponent().appendingPathComponent("Tokens")
        try? FileManager.default.createDirectory(at: tokensDir, withIntermediateDirectories: true)
        self.tokenStore = TokenStore(directoryURL: tokensDir)
        
        let ledgersDir = planStoreDirectory.deletingLastPathComponent().appendingPathComponent("Ledgers")
        self.ledgerStore = LedgerStore(directoryURL: ledgersDir)
        
        self.journalStore = JournalStore(directoryURL: journalStoreDirectory)
        self.executor = Executor(journalStore: self.journalStore)
    }
    
    public func inspect(identity: Identity) async throws -> Footprint {
        let projector = FootprintProjector(engine: engine)
        var footprint = try await projector.project(identity: identity, in: root)
        
        // T-5.3: Storage account (Deferred spike on snapshot accounting)
        let accountant = StorageAccountant()
        let (logical, reclaimable, pinned) = await accountant.account(for: footprint.items)
        
        footprint = Footprint(
            identity: footprint.identity,
            items: footprint.items,
            logicalSizeBytes: logical,
            reclaimableSizeBytes: reclaimable,
            snapshotPinnedBytes: pinned
        )
        
        return footprint
    }
    
    public func plan(intent: PlanIntent) async throws -> Plan {
        let plan = try await makePlan(intent: intent)
        try await planStore.save(plan: plan)
        return plan
    }

    /// Projects, evaluates and plans an intent *without* persisting the
    /// result. `apply` re-plans to revalidate the footprint, and that
    /// throwaway plan must not land in the store beside the real one.
    private func makePlan(intent: PlanIntent) async throws -> Plan {
        let projector = FootprintProjector(engine: engine)
        let footprint: Footprint
        let explicitTargets = intent.explicitTargets
        if !explicitTargets.isEmpty {
            // Bypass evidence engine, project exactly the requested targets.
            // Several targets become one plan, so the user approves the whole
            // selection once rather than once per item.
            let evidence = explicitTargets.map {
                Evidence(url: $0, tier: .A, mechanism: "DirectTarget", humanSentence: "Specific target requested by intent")
            }
            footprint = try await projector.project(identity: intent.subjectIdentity, in: root, explicitEvidence: evidence)
        } else {
            footprint = try await projector.project(identity: intent.subjectIdentity, in: root)
        }

        let evaluated = await safetyEngine.evaluate(footprint: footprint)
        return planner.createPlan(from: evaluated, intent: intent, engineVersion: "1.0.0")
    }
    
    public func explain(planId: UUID) async throws -> String {
        let plan = try await planStore.load(planId: planId)
        return "Plan \(plan.planId) targets \(plan.steps.count) items taking \(plan.expectedTotalBytes) bytes."
    }
    
    #if DEBUG
    /// True when this process is a test run rather than the real app.
    ///
    /// Detected by the XCTest framework being loaded, not by an environment
    /// variable: `XCTestConfigurationFilePath` is set by Xcode's runner but
    /// not by SwiftPM's, so `swift test` would otherwise demand a fingerprint
    /// for every plan it applies on a Mac with working Touch ID.
    static let isAutomatedRun: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        return ProcessInfo.processInfo.environment["BRIM_MCP_TEST"] != nil
    }()
    #endif

    public func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalToken {
        let plan = try await planStore.load(planId: planId)
        
        let hash = try plan.contentHash()

        // A test run must never block on a human. The fallbacks below only
        // cover machines where LAContext is unavailable; on a Mac with working
        // Touch ID the suite raises a real prompt for every plan it applies.
        //
        // Debug-only on purpose: a release build must have no way to reach
        // mintToken without a human, least of all one an environment variable
        // can switch on.
        #if DEBUG
        if Self.isAutomatedRun {
            return await tokenStore.mintToken(planId: planId, planHash: hash, requesterIdentity: requesterIdentity)
        }
        #endif

        // Use LAContext for real human approval
        let context = LAContext()
        let reason = "Approve \(requesterIdentity) deletion of \(plan.intent.subjectIdentity.name) (\(plan.steps.count) items)."
        
        var authError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            do {
                let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                guard success else {
                    throw NSError(domain: "BrimService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Authentication failed."])
                }
            } catch {
                if let laError = error as? LAError, laError.code == .userCancel {
                    // Ignore user cancel and throw standard error
                    throw NSError(domain: "BrimService", code: 403, userInfo: [NSLocalizedDescriptionKey: "User cancelled authentication."])
                }
                // Handle testing environments where LAContext immediately fails
                print("LAContext failed (\(error)), simulating approval for testing fallback if in mock environment")
                #if DEBUG
                if ProcessInfo.processInfo.environment["BRIM_MCP_TEST"] == nil && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                     throw error
                }
                #else
                throw error
                #endif
            }
        } else {
            // No auth mechanism available, or we are in a testing environment without access to LAContext.
            #if DEBUG
            print("LAContext unavailable, allowing fallback for tests")
            #else
            throw authError ?? NSError(domain: "BrimService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Authentication unavailable."])
            #endif
        }
        
        return await tokenStore.mintToken(planId: planId, planHash: hash, requesterIdentity: requesterIdentity)
    }
    private var appliedPlanIds: Set<UUID> = []
    
    public enum ApplyError: Error {
        case planAlreadyApplied
    case validationFailed(String)
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
        
        guard !appliedPlanIds.contains(planId) else {
            throw ApplyError.planAlreadyApplied
        }
        
        // --- T-2.4 Independent Re-validation ---
        // Re-run the evidence scanner and planner to ensure the footprint hasn't mutated (e.g. symlink swap).
        // Deliberately not via plan(intent:): this result is compared and discarded, never stored.
        let revalidatedPlan = try await makePlan(intent: plan.intent)
        
        // Ensure steps match exactly (count, targets, and fingerprints)
        guard plan.steps.count == revalidatedPlan.steps.count else {
            let msg = "Step count mismatch: expected \(plan.steps.count), found \(revalidatedPlan.steps.count)"; print("VALIDATION FAILED: \(msg)"); throw ApplyError.validationFailed(msg)
        }
        
        for i in 0..<plan.steps.count {
            let originalStep = plan.steps[i]
            let newStep = revalidatedPlan.steps[i]
            
            guard originalStep.target == newStep.target else {
                let msg = "Target mismatch at step \(i): expected \(originalStep.target), found \(newStep.target)"; print("VALIDATION FAILED: \(msg)"); throw ApplyError.validationFailed(msg)
            }
            
            guard originalStep.targetFingerprint == newStep.targetFingerprint else {
                let msg = "Fingerprint mismatch at step \(i) for \(originalStep.target)"; print("VALIDATION FAILED: \(msg)"); throw ApplyError.validationFailed(msg)
            }
            
            guard originalStep.targetFingerprint == newStep.targetFingerprint else {
                let msg = "Fingerprint mismatch at step \(i) for target \(originalStep.target): original \(String(describing: originalStep.targetFingerprint)), new \(String(describing: newStep.targetFingerprint))"; print("VALIDATION FAILED: \(msg)"); throw ApplyError.validationFailed(msg)
            }
        }
        
        appliedPlanIds.insert(planId)
        
        let journal = try await executor.execute(plan: plan)
        
        // Record ledger entry
        let outcomes = journal.stepOutcomes.map { (index, resultStr) in
            let status: StepOutcome = resultStr == "ok" ? .success : .failed
            return Outcome(stepIndex: index, result: status, errorMessage: resultStr == "ok" ? nil : resultStr)
        }
        let recovered = max(0, (journal.freeSpaceAfter ?? 0) - (journal.freeSpaceBefore ?? 0))
        let ledgerEntry = LedgerEntry(
            planId: plan.planId,
            planHash: hash,
            executedAt: Date(),
            outcomes: outcomes,
            recoveredBytes: recovered
        )
        try await ledgerStore.write(entry: ledgerEntry)
    }
    
    public func verify(planId: UUID) async throws -> VerificationResult {
        let plan = try await planStore.load(planId: planId)
        
        let journal = try? await journalStore.load(planId: planId)
        let before = journal?.freeSpaceBefore ?? 0
        let after = journal?.freeSpaceAfter ?? 0
        let recoveredBytes = max(0, after - before)
        
        // Re-observe targets using lstat to avoid traversing symlinks
        var targetsRemaining = 0
        for step in plan.steps {
            var statBuf = stat()
            if lstat(step.target, &statBuf) == 0 { // 0 means it exists (symlink or real file)
                // Was it excluded?
                if journal?.stepOutcomes[step.index] == "skipped_due_to_prior_failures" {
                    continue
                }
                print("VERIFY FOUND LEFTOVER TARGET: \(step.target) (Step \(step.index) - \(step.kind))")
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
        let entries = try await ledgerStore.allEntries()
        var plans: [Plan] = []
        for entry in entries {
            if let plan = try? await planStore.load(planId: entry.planId) {
                plans.append(plan)
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
        
        // 1. Restore items from Trash (atomically fails if path is re-occupied)
        let sortedSteps = plan.undoOrderedSteps
        for step in sortedSteps {
            if step.kind == .unloadLaunchdJob {
                try? SafeOps.loadLaunchdJob(path: step.target)
                continue
            }
            if let trashedURL = trashedURLs[step.index] {
                let targetURL = URL(fileURLWithPath: step.target)
                // We MUST ensure the parent directory exists
                let parentURL = targetURL.deletingLastPathComponent()
                if !fm.fileExists(atPath: parentURL.path) {
                    try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
                }
                
                do {
                    try SafeOps.restoreItem(from: trashedURL.path, to: step.target)
                } catch SafeOpsError.pathOccupied {
                    throw NSError(domain: "BrimOps", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path \(step.target) has been re-occupied."])
                }
            }
        }
        
        // 3. Update journal to mark undone? Or just delete journal?
        try await journalStore.delete(planId: planId)
    }

    public func dumpBTM() async throws -> String {
        let task = Process()
        task.launchPath = "/usr/bin/sfltool"
        task.arguments = ["dumpbtm"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        try task.run()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        
        if let string = String(data: data, encoding: .utf8) {
            return string
        } else {
            throw NSError(domain: "BrimService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to decode dumpbtm output."])
        }
    }
    
    public func leftovers() async throws -> [Leftover] {
        let scanner = LeftoversScanner(root: root)
        var knownPastBundleIDs = Set<String>()
        let entries = try await ledgerStore.allEntries()
        for entry in entries {
            if let plan = try? await planStore.load(planId: entry.planId) {
                if let bid = plan.intent.subjectIdentity.bundleID {
                    knownPastBundleIDs.insert(bid)
                }
            }
        }
        
        return try await scanner.scanLeftovers(knownPastBundleIDs: knownPastBundleIDs)
    }
    
    public func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] {
        let scanner = DuplicateScanner()
        return try await scanner.scan(directory: directory)
    }
}