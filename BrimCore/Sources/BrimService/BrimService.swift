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
        self.presenceStore = PresenceStore(directoryURL: tokensDir)
        
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
            // A launchd job file is named as what it is, not as a file.
            // The planner reads the mechanism to decide the steps, and a
            // plist trashed without `launchctl bootout` first leaves the
            // job loaded until the next login: removed on disk, still
            // running, which is the worst of both.
            let evidence = explicitTargets.map { url -> Evidence in
                let isJob = LaunchdJobFile.isOne(url)
                return Evidence(
                    url: url,
                    tier: .A,
                    mechanism: isJob ? "LaunchdSource" : "DirectTarget",
                    humanSentence: isJob
                        ? "A launchd job file named for removal"
                        : "Specific target requested by intent"
                )
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

    /// When the owner enrolled, and when presence was last proved. Persisted,
    /// so relaunching Brim is not by itself a reason to ask again.
    private let presenceStore: PresenceStore
    private let approvalPolicy = ApprovalPolicy()

    /// Whether first-run setup has happened. Nothing is withheld until it
    /// does; the UI uses this to decide whether to offer it.
    public func isEnrolled() async -> Bool {
        await presenceStore.isEnrolled
    }

    /// First-run setup: the owner confirms once, at the machine, that Brim is
    /// theirs. Asked a single time and never again.
    ///
    /// This is deliberately not a gate. It establishes who set Brim up, and
    /// it does not stand in for the confirmation before a permanent
    /// deletion — an authentication at launch proves nothing about the person
    /// present an hour later, which is when it would matter.
    public func enroll() async throws {
        #if DEBUG
        if Self.isAutomatedRun {
            await presenceStore.recordEnrolment()
            return
        }
        #endif

        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            // No biometrics and no password policy available. Enrolment is
            // setup, not a gate, so this must not lock anyone out.
            await presenceStore.recordEnrolment()
            return
        }
        let success = try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            // macOS renders this as "Brim is trying to <reason>", so it has
            // to be a short lowercase verb phrase. The previous wording was
            // a full sentence and came out as "Brim is trying to Confirm
            // this Mac is yours, so Brim can set itself up..".
            localizedReason: "complete first-time setup"
        )
        guard success else {
            throw NSError(domain: "BrimService", code: 403,
                          userInfo: [NSLocalizedDescriptionKey: "Setup was not confirmed."])
        }
        await presenceStore.recordEnrolment()
    }

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

        // Not every plan is worth interrupting a human for. The review
        // sheet is the consent; a fingerprint proves only that a person is
        // at the machine right now, which is worth one interruption before
        // something is destroyed beyond recovery and worth nothing before a
        // file is moved to the Trash.
        //
        // The failure this guards against is not an unauthorised deletion.
        // It is a user asked so often that they stop reading, at which point
        // every prompt in the product has become decoration.
        let requirement = approvalPolicy.requirement(
            for: plan, lastAuthenticated: await presenceStore.lastPresence
        )
        guard case .humanPresence(let reason) = requirement else {
            return await tokenStore.mintToken(
                planId: planId, planHash: hash, requesterIdentity: requesterIdentity
            )
        }

        let context = LAContext()
        var authError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            do {
                let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                guard success else {
                    throw NSError(domain: "BrimService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Authentication failed."])
                }
                // Proving presence once covers the next few minutes of
                // destructive work, the way sudo's timestamp does — including
                // across a relaunch, which is why it is persisted.
                await presenceStore.recordPresence()
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

    public enum UndoError: LocalizedError {
        /// Every step deleted its target outright, so there is nothing to restore.
        case planWasPermanent
        /// The targets were trashed, but the Trash no longer holds them.
        case noLongerInTrash(targets: [String])

        public var errorDescription: String? {
            switch self {
            case .planWasPermanent:
                return "This removal was permanent, so there is nothing to restore."
            case .noLongerInTrash(let targets):
                let names = targets.map { ($0 as NSString).lastPathComponent }
                let list = names.count <= 3
                    ? names.joined(separator: ", ")
                    : "\(names.prefix(3).joined(separator: ", ")) and \(names.count - 3) more"
                return "No longer in the Trash, so it cannot be restored: \(list)."
            }
        }
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
        
        // Re-observe targets using lstat to avoid traversing symlinks.
        // Only path-targeted steps: a bundle identifier is not a file, and
        // lstat-ing one resolves it against the working directory.
        var pathsRemaining = Set<String>()
        for step in plan.steps where step.kind.targetIsPath {
            if journal?.stepOutcomes[step.index] == "skipped_due_to_prior_failures" { continue }
            var statBuf = stat()
            if lstat(step.target, &statBuf) == 0 { // 0 means it exists (symlink or real file)
                print("VERIFY FOUND LEFTOVER TARGET: \(step.target) (Step \(step.index) - \(step.kind))")
                pathsRemaining.insert(step.target)
            }
        }
        let targetsRemaining = pathsRemaining.count

        // Files are not the whole claim. A removed application whose Launch
        // Services record survives still appears in "Open With" and still
        // answers when something resolves its bundle identifier — which is
        // exactly the kind of leftover this product exists to prevent, so
        // verification has to look for it rather than trust the step.
        var staleRegistrations: [URL] = []
        let unregistered = plan.steps.filter { $0.kind == .unregisterLaunchServices }
        if plan.intent.type == .uninstall,
           !unregistered.isEmpty,
           let bundleID = plan.intent.subjectIdentity.bundleID {
            // Scoped to the paths this plan actually removed. Another copy
            // of the same app elsewhere on disk is somebody else's bundle,
            // not a leftover of this uninstall — and reporting it would make
            // the check fire on every machine that has one.
            let removedPaths = Set(unregistered.map {
                URL(fileURLWithPath: $0.target).standardizedFileURL.path
            })
            // Deliberately *not* including where the bundle went. A record
            // pointing at the Trash is not a leftover — the app is there,
            // and it is what macOS records for anything dragged to the bin.
            // The leftover is a record pointing at a path holding nothing,
            // which is what emptying the Trash creates and what the Trash
            // lifecycle has to answer for.
            staleRegistrations = LaunchServicesRegistration
                .registeredApplicationURLs(forBundleID: bundleID)
                .filter { removedPaths.contains($0.standardizedFileURL.path) }
        }

        let success = targetsRemaining == 0 && staleRegistrations.isEmpty
        let reason: String?
        switch (targetsRemaining, staleRegistrations.isEmpty) {
        case (0, true):
            reason = nil
        case (0, false):
            reason = "Every file is gone, but macOS still has this app registered at "
                   + staleRegistrations.map(\.path).joined(separator: ", ") + "."
        case (_, true):
            reason = "\(targetsRemaining) targets still remain."
        default:
            reason = "\(targetsRemaining) targets still remain, and macOS still has this app registered."
        }
        
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

        // Refuse up front rather than restoring some steps and failing on the
        // rest. Two ways a plan cannot be undone: nothing was trashed to begin
        // with, or the Trash has since been emptied.
        guard plan.isReversible else {
            throw UndoError.planWasPermanent
        }

        let missing = plan.steps
            .filter { $0.effectiveDisposition == .trash && $0.kind != .unloadLaunchdJob }
            .compactMap { step -> String? in
                guard let trashed = trashedURLs[step.index] else { return nil }
                return fm.fileExists(atPath: trashed.path) ? nil : step.target
            }
        guard missing.isEmpty else {
            throw UndoError.noLongerInTrash(targets: missing)
        }

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
        
        // Put the registration back with the bundle. The uninstall retracted
        // it deliberately, so restoring the files alone would leave a working
        // application macOS does not know about — no "Open With", no document
        // types, until something happens to rescan it.
        for step in plan.steps where step.executionPhase == .appBundle {
            guard fm.fileExists(atPath: step.target) else { continue }
            try? LaunchServicesRegistration.register(bundlePath: step.target)
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
    
    public func registrations() async -> RegistrationReport {
        let inventory = RegistrationInventory(surfaces: [
            LaunchdRegistrationSurface(),
            BackgroundItemSurface()
        ])
        return RegistrationReport(
            registrations: await inventory.all(in: root),
            coverage: await inventory.coverage(in: root)
        )
    }

    /// A one step plan that runs a tool's own cleanup.
    ///
    /// Built here rather than by the planner, which works from a discovered
    /// footprint. There is no footprint to discover: the step names a
    /// cleanup and the command behind it never leaves BrimOps.
    public func planToolCleanup(id: String, displayed: String) async throws -> Plan {
        let plan = Plan(
            planId: UUID(),
            createdAt: Date(),
            engineVersion: "1.0.0",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            intent: PlanIntent(
                type: .uninstall,
                subjectIdentity: Identity(bundleID: nil, name: displayed),
                requesterKind: "ui",
                requesterIdentity: NSUserName()
            ),
            steps: [Step(
                index: 0,
                kind: .delegateToolCleanup,
                target: id,
                targetFingerprint: nil,
                tier: .A,
                evidence: "Runs the tool's own cleanup: \(displayed)",
                expectedBytes: 0,
                capability: .ok,
                reversible: false,
                costOfError: .low,
                executionPhase: .auxiliary,
                disposition: .delete
            )],
            excludedItems: [],
            expectedTotalBytes: 0
        )
        try await planStore.save(plan: plan)
        return plan
    }

    public func developerCaches() async -> [DeveloperCache] {
        await DeveloperCacheScanner().scan()
    }

    public func sampleEnergy() async -> EnergySampleResult {
        await EnergySampler().sample()
    }

    public func volumes() async -> [VolumeAccount] {
        await VolumeAccountant().accounts()
    }

    public func installedApplications() async throws -> [InstalledApplication] {
        await ApplicationInventory(root: root).installedApplications()
    }

    public func leftovers() async throws -> [Leftover] {
        // A registration whose program has gone names an owner that was
        // recorded present and is not there now — the spec's definition of
        // orphaned, and the thing a user actually notices as "I uninstalled
        // this and it is still here". The sweep already enumerates these.
        var staleRegistrationOwners: [String: String] = [:]
        let inventory = RegistrationInventory(surfaces: [
            LaunchdRegistrationSurface(),
            BackgroundItemSurface()
        ])
        for registration in await inventory.stale(in: root) {
            guard let owner = registration.owningBundleID else { continue }
            staleRegistrationOwners[owner] = registration.evidence
        }

        // Launch Services is one of the four sources T-5.1 requires be
        // searched for an owner, and the only one that can answer both
        // questions at once: a record whose bundle is still there names an
        // owner the directory walk missed, and a record whose bundle has
        // gone *is* the orphan evidence.
        let scanner = LeftoversScanner(
            root: root,
            launchServicesLookup: { LaunchServicesRegistration.registeredApplicationURLs(forBundleID: $0) },
            staleRegistrationOwners: staleRegistrationOwners
        )
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
    
    /// Past removals that could still be undone, judged by what is actually
    /// in the Trash right now rather than by what the journal once recorded.
    /// Emptying the Trash therefore changes this immediately.
    public func recoverableItems() async throws -> [RecoverableItem] {
        let fm = FileManager.default
        var items: [RecoverableItem] = []

        for entry in try await ledgerStore.allEntries() {
            guard let plan = try? await planStore.load(planId: entry.planId),
                  plan.isReversible,
                  let journal = try? await journalStore.load(planId: entry.planId),
                  let trashedURLs = journal.stepTrashedURLs, !trashedURLs.isEmpty
            else { continue }

            // Only count steps whose trashed copy survives; a partially
            // emptied Trash makes the plan unrestorable, not half-restorable.
            let survivors = trashedURLs.filter { fm.fileExists(atPath: $0.value.path) }
            guard survivors.count == trashedURLs.count else { continue }

            let bytes = plan.steps
                .filter { $0.effectiveDisposition == .trash && trashedURLs[$0.index] != nil }
                .reduce(0) { $0 + $1.expectedBytes }

            items.append(RecoverableItem(
                planId: plan.planId,
                name: plan.intent.subjectIdentity.name,
                bytes: bytes,
                removedAt: entry.executedAt
            ))
        }

        return items.sorted { $0.removedAt > $1.removedAt }
    }

    /// Clears Launch Services records that went stale since the last look.
    ///
    /// An uninstall retracts the record for the path an app was installed
    /// at, but a bundle moved to the Trash keeps its name, so macOS
    /// registers it there — accurately, while it is still recoverable.
    /// Emptying the Trash removes the file and leaves that record pointing
    /// at nothing, and macOS does not reliably prune it: a record for
    /// `~/.Trash/…app` was observed surviving the file by some minutes.
    /// That is the moment it becomes a leftover, so that is where it is
    /// cleared.
    ///
    /// Called on every Trash change, so it stays cheap: no Launch Services
    /// lookup at all unless a plan has actually lost a trashed bundle, and
    /// retracting an already-retracted record is a no-op.
    @discardableResult
    public func reconcileRegistrations() async -> [URL] {
        let fm = FileManager.default
        var retracted: [URL] = []

        for entry in (try? await ledgerStore.allEntries()) ?? [] {
            guard let plan = try? await planStore.load(planId: entry.planId),
                  plan.steps.contains(where: { $0.kind == .unregisterLaunchServices }),
                  let bundleID = plan.intent.subjectIdentity.bundleID,
                  let journal = try? await journalStore.load(planId: entry.planId),
                  let trashedURLs = journal.stepTrashedURLs
            else { continue }

            let vanished = trashedURLs.values.filter {
                $0.pathExtension == "app" && !fm.fileExists(atPath: $0.path)
            }
            guard !vanished.isEmpty else { continue }

            let registered = Set(
                LaunchServicesRegistration
                    .registeredApplicationURLs(forBundleID: bundleID)
                    .map(\.standardizedFileURL.path)
            )
            for url in vanished where registered.contains(url.standardizedFileURL.path) {
                try? LaunchServicesRegistration.unregister(bundlePath: url.path)
                retracted.append(url)
            }
        }
        return retracted
    }

    public func scanDuplicates(in directory: URL) async throws -> [DuplicateGroup] {
        let scanner = DuplicateScanner()
        return try await scanner.scan(directory: directory)
    }
}