import Foundation
import os
import BrimCore
import LocalAuthentication
import BrimScan
import BrimProtocol
import BrimOps
import BrimIndex

private let log = BrimLog.make("service")

/// The in-process implementation of the BrimService.
public actor BrimService: BrimServiceProtocol, ApprovalGranting {
    public let root: FileSystemRoot
    private let engine: EvidenceEngine
    private let safetyEngine: SafetyEngine
    private let planner: Planner
    public let planStore: PlanStore
    public let tokenStore: TokenStore
    private let journalStore: JournalStore
    private let ledgerStore: LedgerStore
    private let executor: Executor

    /// The durable store. Written and never read used to be the whole of
    /// it: the schema existed, the module compiled, and the service did
    /// not import it, so there was no history and nothing that needed
    /// one could be built.
    ///
    /// Optional because a database that will not open must not stop Brim
    /// listing what is on the disk. History is a better product, not a
    /// working one.
    private let index: Index?
    
    public init(root: FileSystemRoot, brimAppURL: URL, planStoreDirectory: URL, journalStoreDirectory: URL, consent: ConsentSource? = nil, presence: PresenceCheck? = nil, automatedConsentAllowed: Bool = true) {
        self.root = root
        self.consent = consent
        self.presence = presence
        self.automatedConsentAllowed = automatedConsentAllowed
        
        self.engine = EvidenceEngine(sources: [
            
            AppBundleSource(),
            SandboxContainerSource(),
            InstallerReceiptSource(),
            BundleIdentifierComponentSource(),
            LocationInventorySource(),
            SymlinkIntoBundleSource(),
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
        // Tokens live in memory only. The directory is still here because
        // `PresenceStore` writes to it, and presence, unlike approval, is
        // meant to survive a relaunch.
        self.tokenStore = TokenStore()
        self.presenceStore = PresenceStore(directoryURL: tokensDir)
        
        let ledgersDir = planStoreDirectory.deletingLastPathComponent().appendingPathComponent("Ledgers")
        self.ledgerStore = LedgerStore(directoryURL: ledgersDir)
        
        let indexURL = journalStoreDirectory
            .deletingLastPathComponent().appendingPathComponent("brim.sqlite")
        self.index = (try? DatabaseManager(databaseURL: indexURL)).map(Index.init(dbManager:))

        self.journalStore = JournalStore(directoryURL: journalStoreDirectory)
        self.executor = Executor(journalStore: self.journalStore)
    }
    
    public func inspect(identity: Identity) async throws -> Footprint {
        let projector = FootprintProjector(engine: engine)
        let resolved = await enriched(identity)
        var footprint = try await projector.project(identity: resolved.identity, in: root)
        
        // T-5.3: Storage account (Deferred spike on snapshot accounting)
        let accountant = StorageAccountant()
        let (logical, reclaimable, pinned) = await accountant.account(for: footprint.items)
        
        footprint = Footprint(
            identity: footprint.identity,
            items: footprint.items,
            logicalSizeBytes: logical,
            reclaimableSizeBytes: reclaimable,
            snapshotPinnedBytes: pinned,
            completeness: footprint.completeness.merging(resolved.completeness)
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
        var footprint: Footprint
        let explicitTargets = intent.explicitTargets
        let resolved = explicitTargets.isEmpty
            ? await enriched(intent.subjectIdentity)
            : (identity: intent.subjectIdentity, completeness: ScanCompleteness.complete)
        let subject = resolved.identity
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
            footprint = try await projector.project(identity: subject, in: root, explicitEvidence: evidence)
        } else {
            footprint = try await projector.project(identity: subject, in: root)
        }

        let completeness = footprint.completeness.merging(resolved.completeness)
        footprint = Footprint(
            identity: footprint.identity, items: footprint.items,
            logicalSizeBytes: footprint.logicalSizeBytes,
            reclaimableSizeBytes: footprint.reclaimableSizeBytes,
            snapshotPinnedBytes: footprint.snapshotPinnedBytes,
            completeness: completeness
        )

        let evaluated = await safetyEngine.evaluate(footprint: footprint)
        let plan = planner.createPlan(from: evaluated, intent: intent, engineVersion: EvidenceEngineRevision)
        guard explicitTargets.isEmpty else { return plan }
        let report = await CapabilitySearchScanner().scan(
            identity: subject, in: root, completeness: completeness,
            evidence: footprint.items.map(\.evidence)
        )
        return plan.attaching(report)
    }

    private func enriched(_ identity: Identity) async -> (identity: Identity, completeness: ScanCompleteness) {
        let clean = identity.withoutDerivedSurfaces()
        let candidates = SymlinkIntoBundleSource.bundleLocations(for: identity, in: root)
        let rootPath = root.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let scanRoot = root
        for candidate in candidates {
            let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            guard rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/") else { continue }
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let (surface, capabilities) = await Task.detached {
                BundleSurfaceReader.read(at: candidate, in: scanRoot)
            }.value
            guard let first = surface.components.first else { continue }
            let matches = identity.bundleID == nil || first.bundleIdentifier == identity.bundleID
            guard matches else { continue }
            return (clean.attaching(surface, capabilities: capabilities), capabilities.completeness)
        }
        let gaps = identity.bundlePath.map { ScanCompleteness(unreadable: [$0]) } ?? .complete
        return (clean, gaps)
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
    ///
    /// There was a second way in, an environment variable belonging to the
    /// MCP server's test harness. That server is gone and nothing sets the
    /// variable any more, so what was left was an approval shortcut a debug
    /// build would honour for anything able to set a variable.
    static let isAutomatedRun: Bool = NSClassFromString("XCTestCase") != nil
    #endif

    /// When the owner enrolled, and when presence was last proved. Persisted,
    /// so relaunching Brim is not by itself a reason to ask again.
    private let presenceStore: PresenceStore
    private let approvalPolicy = ApprovalPolicy()

    /// Requests waiting for a person. Held in memory, expiring in minutes,
    /// and carrying no authority of their own.
    private var pendingApprovals: [UUID: ApprovalRequestReceipt] = [:]

    /// The only thing in this process that can ask a person. Nil in any
    /// process that is not Brim's app, which is why nothing outside the
    /// app can approve anything.
    private var consent: ConsentSource?

    /// How presence is proved. Nil means the real thing, which is a system
    /// dialog; a test supplies its own so the gate can be exercised
    /// without one.
    private let presence: PresenceCheck?

    /// Lets a test turn off the debug automation shortcut, so the gate can
    /// be examined as it behaves in a shipped build. Has no effect outside
    /// a debug build, where the shortcut does not exist at all.
    private let automatedConsentAllowed: Bool

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

    // MARK: - Approval

    /// Requests that a person approve a plan. Returns an acknowledgement.
    ///
    /// This deliberately cannot approve anything. It records that a
    /// decision is pending, describes what the decision is about, and hands
    /// back a receipt with no authority in it. The only thing that turns a
    /// receipt into a token is `grantApproval(for:)`, which is not on this
    /// protocol and not reachable across a process boundary.
    ///
    /// The old version minted a token here whenever `ApprovalPolicy`
    /// decided the plan was reversible, which is almost every plan. In the
    /// app that was defensible, because the review sheet had already been
    /// read and confirmed. Anywhere else there is no review sheet, so a
    /// caller could plan, request and apply without a person ever being
    /// involved. That is the one thing the product promises cannot happen.
    public func requestApproval(planId: UUID, requesterIdentity: String) async throws -> ApprovalRequestReceipt {
        let plan = try await planStore.load(planId: planId)
        let hash = try plan.contentHash()
        let now = Date()

        let receipt = ApprovalRequestReceipt(
            requestId: UUID(),
            planId: planId,
            planHash: hash,
            requester: requesterIdentity,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(Self.requestTimeToLive),
            summary: Self.summary(of: plan),
            awaitingHuman: true
        )
        pendingApprovals[receipt.requestId] = receipt
        forgetStaleApprovalRequests(now: now)
        return receipt
    }

    /// Turns an answered request into a token. The only mint site there is.
    ///
    /// Three things have to hold, in this order. Something in this process
    /// has to be able to ask a person, or there is nothing here that can
    /// approve. The plan has to still say what it said when the request was
    /// made, or the answer was given about something else. And where the
    /// plan destroys something nothing can restore, a person has to prove
    /// they are at the machine right now.
    public func grantApproval(for receipt: ApprovalRequestReceipt) async throws -> ApprovalToken {
        guard let pending = pendingApprovals[receipt.requestId],
              pending == receipt,
              Date() < receipt.expiresAt else {
            throw ApprovalError.requestNotPending
        }
        // Single use, whatever happens next. A request that has been
        // answered is spent.
        pendingApprovals.removeValue(forKey: receipt.requestId)

        let plan = try await planStore.load(planId: receipt.planId)
        let hash = try plan.contentHash()
        guard hash == receipt.planHash else {
            throw ApprovalError.planChangedSinceRequest
        }

        // A test run must never block on a human, and must never be able to
        // stand in for one either. Debug-only on purpose: a release build
        // has no path to a token that does not pass through `consent`, least
        // of all one an environment variable can switch on.
        var automated = false
        #if DEBUG
        automated = Self.isAutomatedRun && automatedConsentAllowed
        #endif

        if !automated {
            guard let consent else { throw ApprovalError.noHumanToAsk }
            guard await consent.ask(receipt) else { throw ApprovalError.declined }

            // Not every plan is worth interrupting a human for. The review
            // sheet is the consent; a fingerprint proves only that a person
            // is at the machine right now, which is worth one interruption
            // before something is destroyed beyond recovery and worth
            // nothing before a file is moved to the Trash.
            //
            // The failure this guards against is not an unauthorised
            // deletion. It is a user asked so often that they stop reading,
            // at which point every prompt in the product has become
            // decoration.
            let requirement = approvalPolicy.requirement(
                for: plan, lastAuthenticated: await presenceStore.lastPresence
            )
            if case .humanPresence(let reason) = requirement {
                if let presence {
                    try await presence.prove(reason)
                    await presenceStore.recordPresence()
                } else {
                    try await proveHumanPresence(reason: reason)
                }
            }
        }

        // The one mint in the product, and it is downstream of every check
        // above. `ApprovalGateTests` fails if a second one appears.
        return await tokenStore.mintToken(
            planId: receipt.planId, planHash: hash, requesterIdentity: receipt.requester
        )
    }

    /// Installs the thing that can ask a person. Brim's app calls this at
    /// launch; nothing else does, and nothing else can.
    public func useConsentSource(_ source: ConsentSource?) {
        self.consent = source
    }

    private func proveHumanPresence(reason: String) async throws {
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            // No authentication mechanism at all. In a release build that is
            // a refusal, because the whole point of the prompt is that it
            // cannot be skipped.
            #if DEBUG
            print("LAContext unavailable, allowing fallback for tests")
            return
            #else
            throw authError ?? NSError(
                domain: "BrimService", code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Authentication unavailable."]
            )
            #endif
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason
            )
            guard success else {
                throw NSError(domain: "BrimService", code: 403,
                              userInfo: [NSLocalizedDescriptionKey: "Authentication failed."])
            }
            // Proving presence once covers the next few minutes of
            // destructive work, the way sudo's timestamp does, including
            // across a relaunch, which is why it is persisted.
            await presenceStore.recordPresence()
        } catch let error as LAError where error.code == .userCancel {
            throw NSError(domain: "BrimService", code: 403,
                          userInfo: [NSLocalizedDescriptionKey: "User cancelled authentication."])
        }
    }

    /// What the person is being asked about, in one line.
    static func summary(of plan: Plan) -> String {
        let subject = plan.intent.subjectIdentity.name
        let count = plan.steps.count
        let items = "\(count) \(count == 1 ? "step" : "steps")"
        let permanent = plan.steps.filter { $0.effectiveDisposition == .delete }.count
        if permanent > 0 {
            return "Remove \(subject): \(items), \(permanent) of them permanent."
        }
        return "Remove \(subject): \(items), all recoverable from the Trash."
    }

    private static let requestTimeToLive: TimeInterval = 300

    private func forgetStaleApprovalRequests(now: Date) {
        pendingApprovals = pendingApprovals.filter { $0.value.expiresAt > now }
    }

    private var appliedPlanIds: Set<UUID> = []
    
    public enum ApplyError: LocalizedError {
        case planAlreadyApplied
        case validationFailed(String)
        /// The application, or one of its helpers, is still up.
        case subjectIsRunning(String)

        public var errorDescription: String? {
            switch self {
            case .planAlreadyApplied:
                return "This plan has already been carried out."
            case .validationFailed(let why):
                return "What is on disk no longer matches the plan, so Brim stopped: \(why)"
            case .subjectIsRunning(let why):
                return why
            }
        }
    }

    /// Whether anything belonging to this plan's subject is running.
    ///
    /// Only for a whole-application uninstall. Tidying one leftover cache
    /// while the app happens to be open is not the same hazard, and
    /// refusing it would be the kind of prompt people learn to route
    /// around.
    private func runningApplicationRefusal(for plan: Plan) -> String? {
        guard plan.intent.type == .uninstall, plan.intent.explicitTargets.isEmpty else {
            return nil
        }
        let bundlePath = plan.steps.first { $0.executionPhase == .appBundle }?.target
        return RunningApplications.refusal(
            bundleID: plan.intent.subjectIdentity.bundleID,
            bundlePath: bundlePath
        )
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

        // Checked before the token is spent, so quitting the app and
        // asking again is the whole remedy.
        //
        // Removing a running application does not stop it. It keeps its
        // state in memory and writes it back out when it quits, so the
        // preferences and caches just removed reappear minutes later and
        // the removal looks as though it silently failed.
        if let refusal = runningApplicationRefusal(for: plan) {
            throw ApplyError.subjectIsRunning(refusal)
        }

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
        let searchIsCurrent = plan.capabilityReport == revalidatedPlan.capabilityReport
            && plan.scanCompleteness == revalidatedPlan.scanCompleteness
        guard searchIsCurrent else {
            throw ApplyError.validationFailed("Search coverage changed. Review the plan again.")
        }
        
        // Ensure steps match exactly (count, targets, and fingerprints)
        guard plan.steps.count == revalidatedPlan.steps.count else {
            throw ApplyError.validationFailed(
                "Step count mismatch: expected \(plan.steps.count), "
                + "found \(revalidatedPlan.steps.count)"
            )
        }
        
        for i in 0..<plan.steps.count {
            let originalStep = plan.steps[i]
            let newStep = revalidatedPlan.steps[i]
            
            guard originalStep.target == newStep.target else {
                throw ApplyError.validationFailed(
                    "Target mismatch at step \(i): expected \(originalStep.target), "
                    + "found \(newStep.target)"
                )
            }

            // One guard, not the two that were here. They tested the same
            // thing, so the first always threw and the second, which is the
            // one that says what the fingerprints actually were, never ran.
            guard originalStep.targetFingerprint == newStep.targetFingerprint else {
                throw ApplyError.validationFailed(
                    "Fingerprint mismatch at step \(i) for target \(originalStep.target): "
                    + "original \(String(describing: originalStep.targetFingerprint)), "
                    + "new \(String(describing: newStep.targetFingerprint))"
                )
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

        let (followUps, privacyResetFailed) = await removalFollowUps(plan: plan, journal: journal)

        let success = targetsRemaining == 0 && staleRegistrations.isEmpty && !privacyResetFailed
        let reason = Self.verificationReason(
            pathsRemaining: pathsRemaining, staleRegistrations: staleRegistrations,
            privacyResetFailed: privacyResetFailed
        )
        
        return VerificationResult(
            planId: planId,
            expectedBytes: plan.expectedTotalBytes,
            recoveredBytes: recoveredBytes,
            success: success,
            reason: reason,
            remainingPaths: pathsRemaining,
            followUpActions: followUps.isEmpty ? nil : followUps
        )
    }

    private func removalFollowUps(plan: Plan, journal: JournalEntry?) async -> ([RemovalFollowUp], Bool) {
        let privacyResetFailed = journal != nil && plan.steps.contains { step in
            step.kind == .resetPrivacyGrants && journal?.stepOutcomes[step.index] != "ok"
        }
        let bundleStillPresent = plan.intent.subjectIdentity.bundlePath.map {
            FileManager.default.fileExists(atPath: $0)
        } ?? false
        let needsPrivacyFollowUp = privacyResetFailed
            && plan.intent.type == .uninstall && !bundleStillPresent
        let plannedExtensions = plan.capabilityReport?.checks.first {
            $0.capability == .systemExtension
        }?.registrations ?? []
        var survivingExtensionIDs: Set<String>?
        if !plannedExtensions.isEmpty {
            let snapshot = await SystemExtensionSurface().snapshot(in: root)
            if snapshot.coverage.available {
                survivingExtensionIDs = Set(snapshot.registrations.map(\.identifier))
            }
        }
        var actions = plan.capabilityReport?.followUps(
            survivingSystemExtensionIDs: survivingExtensionIDs,
            privacyResetFailedAfterRemoval: needsPrivacyFollowUp
        ) ?? []
        if needsPrivacyFollowUp, !actions.contains(.restoreAppForPrivacyReset) {
            actions.append(.restoreAppForPrivacyReset)
        }
        return (actions, privacyResetFailed)
    }

    private static func verificationReason(
        pathsRemaining: Set<String>, staleRegistrations: [URL], privacyResetFailed: Bool
    ) -> String? {
        let pathReason: String?
        switch (pathsRemaining.count, staleRegistrations.isEmpty) {
        case (0, true):
            pathReason = nil
        case (0, false):
            pathReason = "Every file is gone, but macOS still has this app registered at "
                + staleRegistrations.map(\.path).joined(separator: ", ") + "."
        case (_, true):
            pathReason = whyTheseRemain(pathsRemaining)
        default:
            pathReason = whyTheseRemain(pathsRemaining)
                + " macOS also still has this app registered."
        }
        let privacyReason = privacyResetFailed ? "Privacy permissions were not reset." : nil
        let combined = [pathReason, privacyReason].compactMap(\.self).joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
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
                return PathExistence.exists(at: trashed) ? nil : step.target
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
            guard PathExistence.exists(atPath: step.target) else { continue }
            try? LaunchServicesRegistration.register(bundlePath: step.target)
        }

        // 3. Update journal to mark undone? Or just delete journal?
        try await journalStore.delete(planId: planId)
    }
    
    /// Gives the executor a way to reach Brim's privileged daemon.
    ///
    /// Set by the application once, after the daemon reports itself
    /// ready. Nothing else in the service knows the daemon exists, which
    /// keeps the privileged path to one line in one place.
    public func usePrivilegedRemover(_ remover: (@Sendable (String) async -> String?)?) async {
        await executor.setPrivilegedRemover(remover)
    }

    public func usePrivilegedReceiptForgetter(
        _ forgetter: (@Sendable (String) async -> String?)?
    ) async {
        await executor.setPrivilegedReceiptForgetter(forgetter)
    }

    /// Every mechanism macOS records software in, in one place.
    ///
    /// Two of these were wired up and the other seven were written and
    /// never called, which is the same failure as a step kind nothing
    /// emits: the code existed, the product did not have the feature.
    static let everySurface: [any RegistrationSurface] = [
        LaunchdRegistrationSurface(),
        BackgroundItemSurface(),
        AppExtensionSurface(),
        SystemExtensionSurface(),
        PrivilegedHelperToolSurface(),
        BundlePluginSurface(),
        ShellProfileSurface(),
        KeychainSurface(),
    ]

    public func registrations() async -> RegistrationReport {
        let inventory = RegistrationInventory(surfaces: Self.everySurface)
        // Both questions at once. These were two sequential awaits, and
        // every surface answers them from the same read: asking what
        // `pluginkit` holds and then asking whether `pluginkit` answered
        // ran the subprocess twice, and the same doubling applied to the
        // Background Task Management store and every directory walk.
        async let registrations = inventory.all(in: root)
        async let coverage = inventory.coverage(in: root)
        return RegistrationReport(registrations: await registrations, coverage: await coverage)
    }

    /// Names what is still there and what stopped it going.
    ///
    /// "2 targets still remain" was the whole message, and it was useless:
    /// it did not say which two, or why, and the answer in the case that
    /// produced it was that both sat in a root-owned directory and no
    /// amount of retrying would have helped. A count is not a finding.
    ///
    /// Then it went the other way. Naming every item and repeating its
    /// reason produced, for fourteen broken commands in one directory,
    /// fourteen copies of the same sentence in a single paragraph: nine
    /// hundred characters of which eight hundred were duplicates, clipped
    /// mid-word by the panel it was shown in. One reason held for all
    /// fourteen and the shape of the text hid that completely.
    ///
    /// So: the reason once, the place once, and then the names. Somebody
    /// reading it learns what went wrong in the first line and which things
    /// it happened to in the last.
    static func whyTheseRemain(
        _ paths: Set<String>,
        capabilityForPath: (String) -> Capability = { RemovalCapability.forDeleting($0) }
    ) -> String {
        let opening = paths.count == 1
            ? "One thing is still there."
            : "\(paths.count) things are still there."

        // Grouped by the folder and the reason, because together they are
        // what somebody can act on. Fourteen names sharing one answer is
        // one paragraph, not fourteen.
        var order: [String] = []
        var names: [String: [String]] = [:]
        for path in paths.sorted() {
            let folder = (path as NSString).deletingLastPathComponent
            let capability = capabilityForPath(path)
            let key = "\(folder)\u{0}\(capability.rawValue)"
            if names[key] == nil { order.append(key) }
            names[key, default: []].append((path as NSString).lastPathComponent)
        }

        let paragraphs = order.flatMap { key -> [String] in
            let parts = key.components(separatedBy: "\u{0}")
            let folder = parts[0]
            let capability = Capability(rawValue: parts[1]) ?? .ok
            let these = names[key] ?? []

            // The folder is the subject wherever the folder is the reason,
            // so one sentence is right for one item and for fourteen. What
            // is left over is per item, and there the item is the subject.
            let reason = RemovalCapability.folderExplanation(capability, folder: folder)
                ?? RemovalCapability.explanation(capability)
                ?? "Brim could not remove \(these.count == 1 ? "it" : "them") and macOS did not "
                    + "say why."
            return [reason, these.joined(separator: ", ")]
        }

        return ([opening] + paragraphs).joined(separator: "\n\n")
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
        let applications = await ApplicationInventory(root: root).installedApplications()

        // Every enumeration is written down, so "what changed" is the
        // last two snapshots differenced and nothing has to watch for
        // installations. Best effort: a history that could not be
        // written must not stop the list being returned.
        await recordSnapshot(of: applications)
        return applications
    }

    private func recordSnapshot(of applications: [InstalledApplication]) async {
        guard let index else { return }
        let observations = applications.compactMap { application -> InstallObservation? in
            guard let bundleID = application.identity.bundleID else { return nil }
            return InstallObservation(
                bundleID: bundleID,
                name: application.name,
                version: application.version,
                bundlePath: application.url.path,
                sizeBytes: application.bundleSizeBytes
            )
        }
        do {
            try await index.recordInstalled(observations)
        } catch {
            // History is snapshots and subtraction, so a snapshot that was
            // not written is a comparison that will silently be made against
            // the wrong pair later.
            log.error("could not write the install snapshot: \(error.localizedDescription)")
        }
    }

    /// How every application on this Mac gets its next version.
    ///
    /// Read from the disk and nothing else: a Sparkle feed is a string in
    /// an Info.plist, an App Store purchase is a receipt file, a Homebrew
    /// cask is a directory in the Caskroom. No request is made, so the
    /// section renders the same with the network off, and software with
    /// no route to a new version is the finding worth making.
    public func updateReport() async -> UpdateReport {
        let scanner = UpdateSourceScanner()
        let casks = scanner.installedCasks()
        let applications = await ApplicationInventory(root: root).installedApplications()

        let coverage = applications.map { application in
            UpdateCoverage(
                application: application,
                sources: scanner.sources(for: application, casks: casks)
            )
        }

        // The background updaters, which answer a different question:
        // who is checking in the background, including for software that
        // is no longer here.
        let report = await registrations()
        let agents = report.registrations.compactMap { registration -> UpdaterAgent? in
            guard let vendor = UpdaterRecogniser.vendor(for: registration.identifier),
                  !registration.isSystemOwned
            else { return nil }
            return UpdaterAgent(
                registration: registration,
                vendor: vendor,
                productIsInstalled: !registration.isStale
            )
        }

        // A vendor updater counts as a route for the application it
        // belongs to, so an app with Keystone behind it is not reported
        // as having no way to update.
        let updatedByVendor = Dictionary(
            agents.filter(\.productIsInstalled).compactMap { agent -> (String, String)? in
                guard let owner = agent.registration.owningBundleID else { return nil }
                return (owner, agent.vendor)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let withVendors = coverage.map { entry -> UpdateCoverage in
            guard let bundleID = entry.application.identity.bundleID,
                  let vendor = updatedByVendor[bundleID]
            else { return entry }
            return UpdateCoverage(
                application: entry.application,
                sources: entry.sources + [.vendorUpdater(vendor: vendor)]
            )
        }

        return UpdateReport(
            coverage: withVendors,
            agents: agents.sorted {
                if $0.productIsInstalled != $1.productIsInstalled { return !$0.productIsInstalled }
                return $0.vendor < $1.vendor
            },
            homebrewPresent: scanner.homebrewIsInstalled()
        )
    }

    /// Checks every application that has a route to a new version.
    ///
    /// On a press, never during a scan: this is the only thing in the
    /// product that reaches the network, and it contacts nothing the
    /// installed software would not contact itself.
    public func checkForUpdates() async -> [AvailableUpdate] {
        let report = await updateReport()
        let checker = UpdateChecker()
        let outdated = await checker.outdatedCasks()
        var available: [AvailableUpdate] = []

        for entry in report.coverage {
            guard let bundleID = entry.application.identity.bundleID else { continue }

            if let cask = entry.homebrewCask, let newer = outdated[cask] {
                available.append(AvailableUpdate(
                    bundleID: bundleID, name: entry.application.name,
                    installed: newer.installed ?? entry.application.version,
                    latest: newer.latest, source: .homebrewCask(name: cask)
                ))
                continue
            }

            for source in entry.sources {
                guard case .sparkle(let feed) = source else { continue }
                guard let latest = await checker.latestVersion(fromFeed: feed),
                      UpdateChecker.isNewer(latest, than: entry.application.version)
                else { continue }
                available.append(AvailableUpdate(
                    bundleID: bundleID, name: entry.application.name,
                    installed: entry.application.version, latest: latest, source: source
                ))
            }
        }

        return available.sorted { $0.name < $1.name }
    }

    /// Casks Homebrew still tracks whose application is gone.
    ///
    /// Found by subtracting what is installed from what Homebrew lists.
    /// Nothing else looks here: the application is in the Trash, so every
    /// scan of the disk says it is gone, while Homebrew goes on offering
    /// to upgrade it.
    public func orphanedCasks() async -> [OrphanedCask] {
        let scanner = UpdateSourceScanner()
        let casks = scanner.installedCasks()
        guard !casks.isEmpty else { return [] }

        let applications = await ApplicationInventory(root: root).installedApplications()
        let claimed = Set(applications.compactMap {
            UpdateSourceScanner.matchingCask(for: $0, among: casks)
        })

        return casks.subtracting(claimed).sorted().map { name in
            let versions = (try? FileManager.default.contentsOfDirectory(
                atPath: "/opt/homebrew/Caskroom/\(name)"
            )) ?? []
            return OrphanedCask(
                name: name,
                installedVersion: versions.first { !$0.hasPrefix(".") }
            )
        }
    }

    /// Clears a cask record whose application is gone.
    public func forgetCask(_ name: String) async -> String? {
        await UpdateChecker().uninstallCask(name)
    }

    /// Installs one update by delegation. Homebrew does the work.
    public func installUpdate(_ update: AvailableUpdate) async -> String? {
        guard case .homebrewCask(let cask) = update.source else {
            return "\(update.name) updates itself; open it to take the new version."
        }
        return await UpdateChecker().upgradeCask(cask)
    }

    /// What is different since the last time Brim looked.
    ///
    /// Empty on a first run, which is the honest answer: there is
    /// nothing to compare against, and inventing a list of "new"
    /// applications the first time somebody opens Brim would make every
    /// later list untrustworthy.
    public func whatChanged() async -> InstallHistory {
        guard let index else { return InstallHistory(changes: [], snapshots: 0) }
        return InstallHistory(
            changes: (try? await index.changesSinceLastScan()) ?? [],
            snapshots: (try? await index.snapshotCount()) ?? 0
        )
    }


    public func leftovers() async throws -> [Leftover] {
        // A registration whose program has gone names an owner that was
        // recorded present and is not there now — the spec's definition of
        // orphaned, and the thing a user actually notices as "I uninstalled
        // this and it is still here". The sweep already enumerates these.
        var staleRegistrationOwners: [String: String] = [:]
        let inventory = RegistrationInventory(surfaces: Self.everySurface)
        for registration in await inventory.stale(in: root) {
            guard let owner = registration.owningBundleID else { continue }
            staleRegistrationOwners[owner] = registration.evidence
        }

        // Launch Services is one of the four sources T-5.1 requires be
        // searched for an owner, and the only one that can answer both
        // questions at once: a record whose bundle is still there names an
        // owner the directory walk missed, and a record whose bundle has
        // gone *is* the orphan evidence.
        // A package manager's record of something it installed, whose
        // application is gone, is evidence of an owner. Nothing was
        // reading it, so a folder Homebrew could have named sat under
        // "nobody claims this" instead.
        let orphanedCaskNames = Set(await orphanedCasks().map(\.name))

        let scanner = LeftoversScanner(
            root: root,
            launchServicesLookup: { LaunchServicesRegistration.registeredApplicationURLs(forBundleID: $0) },
            staleRegistrationOwners: staleRegistrationOwners,
            homebrewOrphans: orphanedCaskNames
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
        var items: [RecoverableItem] = []

        for entry in try await ledgerStore.allEntries() {
            guard let plan = try? await planStore.load(planId: entry.planId),
                  plan.isReversible,
                  let journal = try? await journalStore.load(planId: entry.planId),
                  let trashedURLs = journal.stepTrashedURLs, !trashedURLs.isEmpty
            else { continue }

            // Only count steps whose trashed copy survives; a partially
            // emptied Trash makes the plan unrestorable, not half-restorable.
            let survivors = trashedURLs.filter { PathExistence.exists(at: $0.value) }
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
}
