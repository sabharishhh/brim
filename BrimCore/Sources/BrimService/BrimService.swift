import AppKit
import BrimCore
import BrimIndex
import BrimOps
import BrimProtocol
import BrimScan
import Foundation
import LocalAuthentication
import os

// swiftformat:disable wrapMultilineStatementBraces
private let log = BrimLog.make("service")

/// The in-process implementation of the BrimService.
public actor BrimService: BrimServiceProtocol, ApprovalGranting {
    public let root: FileSystemRoot
    private let brimAppURL: URL
    /// Brim's own bundle, for what a recording should not count.
    var brimBundle: URL {
        brimAppURL
    }

    private let engine: EvidenceEngine
    private let safetyEngine: SafetyEngine
    private let planner: Planner
    public let planStore: PlanStore
    public let tokenStore: TokenStore
    let journalStore: JournalStore
    /// Recordings of installs: one under way, and the ones kept.
    let recordingStore: InstallRecordingStore
    var hasRecheckedPendingRemovals = false
    private let ledgerStore: LedgerStore
    let executor: Executor
    var recoveryReader: (@Sendable () async throws -> [RecoveryCopy])?
    private let toolCleanupClient: ToolCleanup.Client
    private let launchdRuntime: LaunchdRuntimeClient
    private var leftoversTask: Task<[Leftover], Error>?
    private var applicationInventoryTask: Task<[InstalledApplication], Never>?
    private var pendingInterruptedUpdates: [String: String] = [:]
    private var applicationInventoryReader: (@Sendable () async -> [InstalledApplication])?
    private var updateRecoveryReader: (@Sendable () async -> [String: String])?
    private var activePlans = Set<UUID>()

    /// Whether a removal, restoration or check is changing this plan now.
    func isOperating(on planId: UUID) -> Bool {
        activePlans.contains(planId)
    }

    private func beginOperation(planId: UUID) throws {
        guard activePlans.insert(planId).inserted else {
            throw NSError(domain: "BrimService", code: 409, userInfo: [
                NSLocalizedDescriptionKey: "This removal is already being changed or checked. "
                    + "Try again when it finishes."
            ])
        }
    }

    /// The durable store. Written and never read used to be the whole of
    /// it: the schema existed, the module compiled, and the service did
    /// not import it, so there was no history and nothing that needed
    /// one could be built.
    ///
    /// Optional because a database that will not open must not stop Brim
    /// listing what is on the disk. History is a better product, not a
    /// working one.
    private let index: Index?

    public init(
        root: FileSystemRoot, brimAppURL: URL, planStoreDirectory: URL, journalStoreDirectory: URL,
        consent: ConsentSource? = nil, presence: PresenceCheck? = nil, automatedConsentAllowed: Bool = true,
        toolCleanupClient: ToolCleanup.Client = .init(), tokenStore: TokenStore = .init(),
        launchdRuntime: LaunchdRuntimeClient = .init()
    ) {
        self.root = root
        self.toolCleanupClient = toolCleanupClient
        self.launchdRuntime = launchdRuntime
        self.brimAppURL = brimAppURL
        self.consent = consent
        self.presence = presence
        self.automatedConsentAllowed = automatedConsentAllowed

        // The production search, and what kept recordings say each app
        // created. The recording source reads its file directly, because a
        // search cannot wait on another actor.
        let recordingsDirectory = journalStoreDirectory.deletingLastPathComponent()
            .appendingPathComponent("Recordings", isDirectory: true)
        recordingStore = InstallRecordingStore(directory: recordingsDirectory)
        let kept = recordingsDirectory.appendingPathComponent("recordings.json")
        engine = EvidenceEngine(sources: EvidenceEngine.standard.sources + [
            InstallRecordingSource(recordings: { InstallRecordingStore.load(kept) })
        ])

        let checker = SafetyChecker(root: root, brimAppURL: brimAppURL)
        let vetoEngine = TierSVetoEngine(root: root, lookup: { identifier in
            guard root.rootURL.standardizedFileURL.path == "/" else { return [] }
            return try LaunchServicesRegistration.checkedApplicationURLs(forBundleID: identifier)
        })
        safetyEngine = SafetyEngine(safetyChecker: checker, vetoEngine: vetoEngine)
        planner = Planner()
        planStore = PlanStore(directoryURL: planStoreDirectory)
        let tokensDir = planStoreDirectory.deletingLastPathComponent().appendingPathComponent("Tokens")
        try? FileManager.default.createDirectory(at: tokensDir, withIntermediateDirectories: true)
        // Tokens live in memory only. The directory is still here because
        // `PresenceStore` writes to it, and presence, unlike approval, is
        // meant to survive a relaunch.
        self.tokenStore = tokenStore
        presenceStore = PresenceStore(directoryURL: tokensDir)

        let ledgersDir = planStoreDirectory.deletingLastPathComponent().appendingPathComponent("Ledgers")
        ledgerStore = LedgerStore(directoryURL: ledgersDir)

        let indexURL = journalStoreDirectory
            .deletingLastPathComponent().appendingPathComponent("brim.sqlite")
        index = (try? DatabaseManager(databaseURL: indexURL)).map(Index.init(dbManager:))

        journalStore = JournalStore(directoryURL: journalStoreDirectory)
        executor = Executor(
            journalStore: journalStore,
            toolCleanupClient: toolCleanupClient,
            launchdRuntime: launchdRuntime
        )
    }

    public func inspect(identity: Identity) async throws -> Footprint {
        let projector = FootprintProjector(engine: engine)
        let resolved = try await enriched(identity)
        let footprint = try await projector.project(identity: resolved.identity, in: root)
        let accounting = await StorageAccountant().account(for: footprint.items)
        try Task.checkCancellation()
        return accounting.applying(to: footprint, additionalCompleteness: resolved.completeness)
    }

    public func plan(intent: PlanIntent) async throws -> Plan {
        let plan = try await makePlan(intent: intent)
        try Task.checkCancellation()
        try await planStore.save(plan: plan)
        return plan
    }

    /// Projects, evaluates and plans an intent *without* persisting the
    /// result. `apply` re-plans to revalidate the footprint, and that
    /// throwaway plan must not land in the store beside the real one.
    private func makePlan(intent: PlanIntent) async throws -> Plan {
        if intent.type == .toolCleanup {
            return try await makeToolCleanupPlan(intent)
        }
        guard intent.toolCleanup == nil else { throw ToolCleanup.CleanupError.bindingChanged }
        let projector = FootprintProjector(engine: engine)
        var footprint: Footprint
        let explicitTargets = intent.explicitTargets
        let recoveryCopies = try await reviewedRecoveryCopies(for: explicitTargets)
        let ordinaryTargets = explicitTargets.filter { RecoveryCopy.identifier(for: $0.path) == nil }
        let resolved = explicitTargets.isEmpty
            ? try await enriched(intent.subjectIdentity)
            : (identity: intent.subjectIdentity, completeness: ScanCompleteness.complete)
        let subject = resolved.identity
        if !explicitTargets.isEmpty {
            try Self.validateExclusions(in: intent)
            let evidence = Self.explicitEvidence(for: ordinaryTargets)
            footprint = ordinaryTargets.isEmpty
                ? Footprint(identity: subject, items: [])
                : try await projector.project(identity: subject, in: root, explicitEvidence: evidence)
            footprint = await Self.classifiedDeveloperTargets(footprint, in: root)
        } else {
            footprint = try await projector.project(identity: subject, in: root)
        }

        let package: (installation: HomebrewInstallation?, completeness: ScanCompleteness) = explicitTargets.isEmpty
            ? await Self.homebrewInstallation(for: subject, in: root) : (nil, .complete)
        let completeness = footprint.completeness.merging(resolved.completeness).merging(package.completeness)
        footprint = Footprint(
            identity: footprint.identity, items: footprint.items,
            logicalSizeBytes: footprint.logicalSizeBytes,
            reclaimableSizeBytes: footprint.reclaimableSizeBytes,
            snapshotPinnedBytes: footprint.snapshotPinnedBytes,
            completeness: completeness
        )

        let evaluated = await safetyEngine.evaluate(footprint: footprint)
        try Task.checkCancellation()
        var payloads: [String: [String]] = [:]
        for item in evaluated.items where item.footprintItem.evidence.mechanism == "InstallerReceiptSource" {
            guard case .selected = item.selection else { continue }
            let receipt = item.footprintItem.evidence.url
            let identifier = receipt.deletingPathExtension().lastPathComponent
            if let paths = InstallerReceiptSource.reviewedPayload(for: identifier, receiptURL: receipt, in: root) {
                payloads[identifier] = paths
            }
        }
        let report = await registrationSearchReport(evaluated: evaluated, intent: intent,
                                                    footprint: footprint, payloads: payloads)
        try Task.checkCancellation()
        let plan = planner.createPlan(from: evaluated, intent: intent, engineVersion: EvidenceEngineRevision,
                                      capabilityReport: report, receiptPayloads: payloads)
        return plan.attaching(report).recording(package.installation).addingRecoveryRemoval(recoveryCopies)
    }

    private func registrationSearchReport(
        evaluated: EvaluatedFootprint, intent: PlanIntent, footprint: Footprint, payloads: [String: [String]]
    ) async -> CapabilitySearchReport? {
        let selected = planner.createPlan(from: evaluated, intent: intent, engineVersion: EvidenceEngineRevision,
                                          receiptPayloads: payloads)
        let removalLocations = selected.steps.filter {
            [.trashPath, .trashPathPrivileged].contains($0.kind)
        }.map(\.target)
        if intent.explicitTargets.isEmpty {
            return await CapabilitySearchScanner().scan(
                identity: footprint.identity, in: root, completeness: footprint.completeness,
                evidence: footprint.items.map(\.evidence), removalLocations: removalLocations
            )
        }
        let check = CapabilitySearchScanner.launchServicesCheck(
            identity: footprint.identity, in: root, removalLocations: removalLocations, discoverApplications: true
        )
        return check.registrations.isEmpty && (check.coverage.available || check.coverage.absence == .byDesign)
            ? nil : CapabilitySearchReport(checks: [check], signatureCoverage: [])
    }

    private func enriched(_ identity: Identity) async throws -> (identity: Identity, completeness: ScanCompleteness) {
        let clean = identity.withoutDerivedSurfaces()
        let candidates = SymlinkIntoBundleSource.bundleLocations(for: identity, in: root)
        let rootPath = root.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        for candidate in candidates {
            try Task.checkCancellation()
            let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            guard rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/") else { continue }
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let (surface, capabilities) = try await Self.readBundleSurface(at: candidate, in: root)
            guard let first = surface.components.first else { continue }
            let matches = identity.bundleID == nil || first.bundleIdentifier == identity.bundleID
            guard matches else { continue }
            return (clean.attaching(surface, capabilities: capabilities), capabilities.completeness)
        }
        let gaps = identity.bundlePath.map { ScanCompleteness(unreadable: [$0]) } ?? .complete
        return (clean, gaps)
    }

    @concurrent
    private static func readBundleSurface(
        at url: URL, in root: FileSystemRoot
    ) async throws -> (IdentitySurface, CapabilitySurface) {
        try Task.checkCancellation()
        let result = BundleSurfaceReader.read(at: url, in: root)
        try Task.checkCancellation()
        return result
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
        try beginOperation(planId: receipt.planId)
        defer { activePlans.remove(receipt.planId) }
        guard authenticatedPrivilegedPlans[receipt.planId] == nil else {
            throw ApprovalError.requestNotPending
        }
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

            try await authenticateApproval(plan)
        }

        // The one mint in the product, and it is downstream of every check
        // above. `ApprovalGateTests` fails if a second one appears.
        return await tokenStore.mintToken(
            planId: receipt.planId, planHash: hash, requesterIdentity: receipt.requester
        )
    }

    private func authenticateApproval(_ plan: Plan) async throws {
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
        let requirement = await approvalPolicy.requirement(
            for: plan, lastAuthenticated: presenceStore.lastPresence
        )
        if plan.steps.contains(where: { $0.capability == .needsHelper }), let beginPrivilegedBatch {
            // macOS administrator authentication and the signed root peer
            // prove presence before approval is minted. Retain this exact
            // connection for the selection rather than asking twice.
            if let problem = await beginPrivilegedBatch() {
                throw NSError(domain: "BrimApproval", code: 403,
                              userInfo: [NSLocalizedDescriptionKey: problem])
            }
            let generation = UUID()
            authenticatedPrivilegedPlans[plan.planId] = generation
            await presenceStore.recordPresence()
            Task {
                try? await Task.sleep(for: .seconds(90))
                await expirePrivilegedApproval(plan.planId, generation: generation)
            }
        } else if case let .humanPresence(reason) = requirement {
            if let presence {
                try await presence.prove(reason)
                await presenceStore.recordPresence()
            } else {
                try await proveHumanPresence(reason: reason)
            }
        }
    }

    /// Installs the thing that can ask a person. Brim's app calls this at
    /// launch; nothing else does, and nothing else can.
    public func useConsentSource(_ source: ConsentSource?) {
        consent = source
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
        if plan.steps.contains(where: { $0.kind == .trashPathPrivileged }) {
            return "Remove \(subject): \(items), including items set aside by the helper without a restore action."
        }
        return "Remove \(subject): \(items). Trash items can be restored until the Trash is emptied."
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
                "This plan has already been carried out."
            case let .validationFailed(why):
                "What is on disk no longer matches the plan, so Brim stopped: \(why)"
            case let .subjectIsRunning(why):
                why
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
            case let .noLongerInTrash(targets):
                let names = targets.map { ($0 as NSString).lastPathComponent }
                let list = names.count <= 3
                    ? names.joined(separator: ", ")
                    : "\(names.prefix(3).joined(separator: ", ")) and \(names.count - 3) more"
                return "No longer in the Trash, so it cannot be restored: \(list)."
            }
        }
    }

    public func apply(planId: UUID, token: ApprovalToken) async throws {
        try beginOperation(planId: planId)
        defer { activePlans.remove(planId) }
        let authenticated = authenticatedPrivilegedPlans.removeValue(forKey: planId) != nil
        do {
            try await applyApprovedPlan(planId: planId, token: token, authenticated: authenticated)
        } catch {
            if authenticated {
                await endPrivilegedBatch?()
            }
            throw error
        }
        if authenticated {
            retainPrivilegedVerification(planId)
        }
    }

    private func retainPrivilegedVerification(_ planId: UUID) {
        let generation = UUID()
        authenticatedPrivilegedPlans[planId] = generation
        Task {
            try? await Task.sleep(for: .seconds(90))
            await expirePrivilegedApproval(planId, generation: generation)
        }
    }

    private func expirePrivilegedApproval(_ planId: UUID, generation: UUID) async {
        guard authenticatedPrivilegedPlans[planId] == generation else { return }
        authenticatedPrivilegedPlans.removeValue(forKey: planId)
        await endPrivilegedBatch?()
    }

    private func applyApprovedPlan(planId: UUID, token: ApprovalToken, authenticated: Bool) async throws {
        let plan = try await planStore.load(planId: planId)
        let hash = try plan.contentHash()

        // Checked before the token is spent, so quitting the app and
        // asking again is the whole remedy.
        //
        // Removing a running application does not stop it. It keeps its
        // state in memory and writes it back out when it quits, so the
        // preferences and caches just removed reappear minutes later and
        // the removal looks as though it silently failed.
        if plan.intent.type == .uninstall, plan.intent.explicitTargets.isEmpty {
            _ = await RunningApplications.quitBackgroundParts(
                bundleID: plan.intent.subjectIdentity.bundleID,
                bundlePath: plan.steps.first { $0.executionPhase == .appBundle }?.target
            )
        }
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

        let needsAdministrator = plan.steps.contains { $0.capability == .needsHelper }
        if needsAdministrator, !authenticated, let beginPrivilegedBatch,
           let problem = await beginPrivilegedBatch() {
            throw ApplyError.validationFailed(problem)
        }
        do {
            // --- T-2.4 Independent Re-validation ---
            // Re-run the evidence scanner and planner to ensure the footprint hasn't mutated (e.g. symlink swap).
            // Deliberately not via plan(intent:): this result is compared and discarded, never stored.
            let revalidatedPlan = try await makePlan(intent: plan.intent)
            try validateReviewedPlan(plan, rebuilt: revalidatedPlan)

            // Revalidation awaits other work, so another application of this plan
            // may have completed while the actor was suspended.
            guard !appliedPlanIds.contains(planId) else { throw ApplyError.planAlreadyApplied }
            appliedPlanIds.insert(planId)

            let journal = try await executor.execute(plan: plan)

            let ledgerEntry = Self.ledgerEntry(for: plan, hash: hash, journal: journal)
            try await ledgerStore.write(entry: ledgerEntry)
            // Update list presentation before closing the authenticated process.
            if needsAdministrator {
                _ = try? await recoveryReader?()
            }
        } catch {
            if needsAdministrator, !authenticated {
                await endPrivilegedBatch?()
            }
            throw error
        }
        if needsAdministrator, !authenticated {
            await endPrivilegedBatch?()
        }
    }

    private static func ledgerEntry(for plan: Plan, hash: String, journal: JournalEntry) -> LedgerEntry {
        // Record ledger entry
        let outcomes = journal.stepOutcomes.map { index, resultStr in
            let completed = resultStr == "ok" || resultStr == "already_gone"
            let status: StepOutcome = completed ? .success : .failed
            return Outcome(stepIndex: index, result: status, errorMessage: completed ? nil : resultStr)
        }
        let recovered = Self.observedSpaceIncrease(before: journal.freeSpaceBefore, after: journal.freeSpaceAfter)
        return LedgerEntry(
            planId: plan.planId,
            planHash: hash,
            executedAt: Date(),
            outcomes: outcomes,
            recoveredBytes: recovered
        )
    }

    private func validateReviewedPlan(_ plan: Plan, rebuilt revalidatedPlan: Plan) throws {
        try validateToolCleanup(plan, rebuilt: revalidatedPlan)
        let searchIsCurrent = plan.capabilityReport?.reviewScope == revalidatedPlan.capabilityReport?.reviewScope
            && plan.scanCompleteness == revalidatedPlan.scanCompleteness
            && plan.homebrewInstallation == revalidatedPlan.homebrewInstallation
            && plan.survivingCopies == revalidatedPlan.survivingCopies
            && plan.protectedComponentIdentifiers == revalidatedPlan.protectedComponentIdentifiers
            && plan.receiptPayloads == revalidatedPlan.receiptPayloads
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

        for i in 0 ..< plan.steps.count {
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
            let sameAction = originalStep.kind == newStep.kind
                && originalStep.effectiveDisposition == newStep.effectiveDisposition
                && originalStep.capability == newStep.capability
                && originalStep.executionPhase == newStep.executionPhase
            guard sameAction else {
                throw ApplyError.validationFailed("The required action changed. Review the plan again.")
            }
            guard originalStep.targetFingerprint == newStep.targetFingerprint else {
                throw ApplyError.validationFailed(
                    "Fingerprint mismatch at step \(i) for target \(originalStep.target): "
                        + "original \(String(describing: originalStep.targetFingerprint)), "
                        + "new \(String(describing: newStep.targetFingerprint))"
                )
            }
        }
    }

    private func validateToolCleanup(_ plan: Plan, rebuilt revalidatedPlan: Plan) throws {
        guard plan.toolCleanupBinding == revalidatedPlan.toolCleanupBinding else {
            throw ApplyError.validationFailed("The tool or its cleanup scope changed. Review the plan again.")
        }
        if plan.intent.type == .toolCleanup, plan.steps != revalidatedPlan.steps {
            throw ApplyError.validationFailed("The cleanup command changed. Review the plan again.")
        }
    }

    public func verify(planId: UUID) async throws -> VerificationResult {
        try beginOperation(planId: planId)
        defer { activePlans.remove(planId) }
        let authenticated = authenticatedPrivilegedPlans.removeValue(forKey: planId) != nil
        do {
            let result = try await verifyPlan(planId: planId)
            if authenticated {
                await endPrivilegedBatch?()
            }
            return result
        } catch {
            if authenticated {
                await endPrivilegedBatch?()
            }
            throw error
        }
    }

    private func verifyPlan(planId: UUID) async throws -> VerificationResult {
        let verificationStartedAt = Date()
        let plan = try await planStore.load(planId: planId)

        let journal = try? await journalStore.load(planId: planId)
        let executionEvidenceUnavailable = !plan.steps.isEmpty && journal == nil
        if plan.steps.contains(where: { $0.kind == .delegateToolCleanup }) {
            return try await verifyToolCleanup(plan: plan, journal: journal, observedAt: verificationStartedAt)
        }
        let recoveredBytes = Self.observedSpaceIncrease(
            before: journal?.freeSpaceBefore, after: journal?.freeSpaceAfter
        )
        let freeSpaceMeasured = journal?.freeSpaceBefore != nil && journal?.freeSpaceAfter != nil

        // Re-observe targets using lstat to avoid traversing symlinks.
        // Only path-targeted steps: a bundle identifier is not a file, and
        // lstat-ing one resolves it against the working directory.
        var pathsRemaining = Set<String>()
        var unknownPaths = Set<String>()
        let recoveryObservations = await recoveryPresence(for: plan)
        for step in plan.steps where step.kind.targetIsPath {
            let presence = recoveryObservations[step.target] ?? PathObservation.observe(step.target)
            if presence.isAbsent {
                continue
            }
            if presence.isUnknown {
                unknownPaths.insert(step.target)
            }
            if presence.isPresent,
               PreferenceDomains.domain(forPlistAt: step.target) != nil,
               PreferenceDomains.isEmptyStub(atPath: step.target) {
                continue
            }
            pathsRemaining.insert(step.target)
        }
        let targetsRemaining = pathsRemaining.count

        let postChecks = await registrationPostChecks(plan: plan, journal: journal)
        let staleRegistrations = postChecks.filter { $0.capability == .launchServices }
            .flatMap(\.remaining).compactMap { $0.programPath.map { URL(fileURLWithPath: $0) } }
        let followUpResult = await removalFollowUps(
            plan: plan,
            journal: journal,
            postChecks: postChecks
        )
        var followUps = followUpResult.actions
        let privacyResetFailed = followUpResult.privacyResetFailed
        let survivingExtensions = followUpResult.survivingExtensions
        followUps += Self.registrationRoutes(plan: plan, observations: postChecks)
        followUps.removeAll { $0 == .vendorUninstaller }
        // A failed step whose path is still there is explained with that
        // path. Saying "some planned actions could not be completed" as
        // well added a vaguer copy of the same news.
        let otherActionsFailed = journal != nil && plan.steps.contains { step in
            guard step.kind != .resetPrivacyGrants else { return false }
            guard !(step.kind.targetIsPath && pathsRemaining.contains(step.target)) else { return false }
            let outcome = journal?.stepOutcomes[step.index]
            return outcome != "ok" && outcome != "already_gone"
        }

        let success = targetsRemaining == 0 && staleRegistrations.isEmpty
            && !privacyResetFailed && !otherActionsFailed && !executionEvidenceUnavailable
            && !postChecks.contains(where: { !$0.remaining.isEmpty })
            && RemovalReport.unansweredChecks(postChecks, declaredNone: RemovalReport.declaredNone(in: plan)).isEmpty
        let recorded = Self.recordedOutcomes(plan: plan, journal: journal, remaining: pathsRemaining)
        let observedReason = Self.verificationReason(
            pathsRemaining: pathsRemaining,
            recorded: recorded,
            staleRegistrations: staleRegistrations,
            privacyResetFailed: privacyResetFailed, otherActionsFailed: otherActionsFailed
        )
        let receiptReason = executionEvidenceUnavailable
            ? "Execution receipts could not be read. Completed actions are unknown." : nil
        let reason = [observedReason, receiptReason]
            .compactMap(\.self).joined(separator: "\n\n")

        // Teams' device was still offered in every app's microphone list
        // after its driver had gone, because Core Audio had it loaded.
        let removedDriver = plan.steps.contains { step in
            step.kind.targetIsPath && !pathsRemaining.contains(step.target)
                && (step.target as NSString).deletingLastPathComponent.hasSuffix("/Audio/Plug-Ins/HAL")
        }
        if removedDriver {
            followUps.append(.restartForAudioDevice)
        }

        let result = VerificationResult(
            planId: planId,
            expectedBytes: plan.expectedTotalBytes,
            recoveredBytes: recoveredBytes,
            success: success,
            reason: reason.isEmpty ? nil : reason,
            remainingPaths: pathsRemaining,
            followUpActions: followUps.isEmpty ? nil : followUps,
            report: RemovalReport.build(
                plan: plan, remaining: pathsRemaining, recorded: recorded,
                staleRegistrations: staleRegistrations.count, privacyResetFailed: privacyResetFailed,
                survivingExtensions: survivingExtensions,
                unknownPaths: unknownPaths, registrationObservations: postChecks,
                completedActions: plan.steps.filter {
                    $0.kind == .resetPrivacyGrants && journal?.stepOutcomes[$0.index] == "ok"
                }.map { "Permission reset command completed for " + $0.target },
                verificationStartedAt: verificationStartedAt
            ),
            packageRecord: plan.homebrewInstallation.map(PackageRecordResult.observe),
            freeSpaceMeasured: freeSpaceMeasured,
            observedAt: verificationStartedAt
        )
        if journal != nil {
            try await journalStore.recordVerification(result)
        }
        return result
    }

    private func verifyToolCleanup(
        plan: Plan, journal: JournalEntry?, observedAt: Date
    ) async throws -> VerificationResult {
        let outcome = journal?.stepOutcomes[0]
        let completed = outcome == "ok"
        let state: ToolCleanupResult.State = completed ? .completed : (outcome == nil ? .notRun : .failed)
        let command = plan.toolCleanupBinding?.displayed ?? plan.steps.first?.evidence ?? "Tool cleanup"
        let cleanup = ToolCleanupResult(state: state, command: command,
                                        scope: plan.toolCleanupBinding?.scope, failure: completed ? nil : outcome)
        let result = VerificationResult(planId: plan.planId, expectedBytes: 0, recoveredBytes: 0, success: completed,
                                        reason: journal == nil ? "Execution receipts could not be read."
                                            : (completed ? nil : outcome),
                                        toolCleanup: cleanup, observedAt: observedAt)
        if journal != nil {
            try await journalStore.recordVerification(result)
        }
        return result
    }

    private func registrationPostChecks(plan: Plan, journal: JournalEntry?) async -> [RegistrationVerification] {
        guard plan.intent.type == .uninstall else { return [] }
        let observedAt = Date()
        let recoveries = Array(journal?.stepTrashedURLs?.values ?? [Int: URL]().values)
        var expected = plan.capabilityReport?.checks.flatMap(\.registrations) ?? []
        expected += plan.steps.filter { $0.kind == .unregisterLaunchServices }.map { step in
            Registration(kind: .launchServices, identifier: step.registrationBundleID ?? step.target,
                         label: URL(fileURLWithPath: step.target).lastPathComponent,
                         programPath: step.target, targetExists: true, evidence: step.evidence)
        }
        if !plan.intent.explicitTargets.isEmpty {
            guard expected.contains(where: { $0.kind == .launchServices })
                || plan.capabilityReport?.checks.contains(where: { $0.capability == .launchServices }) == true
            else { return [] }
            let check = CapabilitySearchScanner.launchServicesCheck(
                identity: plan.intent.subjectIdentity, in: root, expectedRegistrations: expected,
                recoveryLocations: recoveries,
                reviewedCoverage: plan.capabilityReport?.checks.first { $0.capability == .launchServices }?.coverage
            )
            return [Self.registrationObservation(check, copies: [], recoveries: recoveries, observedAt: observedAt)]
        }
        guard let fresh = await CapabilitySearchScanner().scan(
            identity: plan.intent.subjectIdentity, in: root,
            completeness: plan.scanCompleteness ?? .complete,
            expectedRegistrations: expected,
            recoveryLocations: recoveries
        ) else { return [] }
        let copies = (plan.survivingCopies ?? []).filter { copy in
            guard let path = copy.bundlePath, PathObservation.observe(path).isPresent,
                  let metadata = NSDictionary(contentsOf: URL(fileURLWithPath: path)
                      .appendingPathComponent("Contents/Info.plist")),
                  let identifier = metadata["CFBundleIdentifier"] as? String else { return false }
            return identifier == copy.bundleID
        }
        var results = fresh.checks.filter { $0.capability != .applicationGroups }.map {
            Self.registrationObservation($0, copies: copies, recoveries: recoveries, observedAt: observedAt,
                                         reviewedCoverage: plan.capabilityReport?.checks
                                             .first { $0.capability == .launchServices }?.coverage)
        }
        if let index = results.firstIndex(where: { $0.capability == .launchdJob }) {
            let reviewed = plan.capabilityReport?.checks.first { $0.capability == .launchdJob }?.registrations ?? []
            results[index] = await recheckReviewedJobs(results[index], reviewed: reviewed, observedAt: observedAt)
        }
        return results
    }

    private static func registrationObservation(
        _ check: CapabilitySearchReport.Check, copies: [Identity], recoveries: [URL], observedAt: Date,
        reviewedCoverage: RegistrationCoverage? = nil
    ) -> RegistrationVerification {
        let coverage: RegistrationCoverage = if check.capability == .launchServices,
                                                reviewedCoverage?.available == false,
                                                reviewedCoverage?.absence != .byDesign {
            .unavailable(.launchServices, "The reviewed application search was incomplete.")
        } else {
            check.coverage
        }
        var remaining: [Registration] = []
        var preserved: [Registration] = []
        var recoveryCopies: [Registration] = []
        for record in check.registrations {
            let shared = copies.contains { copy in
                record.belongs(to: copy, bundleURL: copy.bundlePath.map { URL(fileURLWithPath: $0) })
            }
            let inRecovery = record.programPath.map { path in
                recoveries.contains {
                    let recovery = $0.resolvingSymlinksInPath().path
                    let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    return candidate == recovery || candidate.hasPrefix(recovery + "/")
                }
            } ?? false
            if inRecovery {
                recoveryCopies.append(record)
            } else if shared {
                preserved.append(record)
            } else {
                remaining.append(record)
            }
        }
        return RegistrationVerification(capability: check.capability, observedAt: check.observedAt ?? observedAt,
                                        readerVersion: check.readerVersion ?? 2, coverage: coverage,
                                        remaining: remaining, preserved: preserved,
                                        recoveryCopies: recoveryCopies)
    }

    func recheckReviewedJobs(_ original: RegistrationVerification, reviewed: [Registration],
                             observedAt: Date) async -> RegistrationVerification {
        var remaining = original.remaining
        var coverage = original.coverage
        for record in reviewed {
            guard record.namespace != nil else {
                coverage = .unavailable(.launchdJob, "A saved job has no verified launchd namespace.")
                continue
            }
            let presence = await launchdRuntime.observeReviewed(record)
            let retained = original.preserved + (original.recoveryCopies ?? [])
            if presence.isPresent, !remaining.contains(where: { $0.id == record.id }),
               !retained.contains(where: { $0.id == record.id }) {
                remaining.append(Registration(
                    kind: record.kind, identifier: record.identifier, label: record.label,
                    owningBundleID: record.owningBundleID, programPath: record.programPath,
                    targetExists: true, recordPath: record.recordPath,
                    evidence: "The reviewed background job is still loaded in launchd.",
                    isSystemOwned: record.isSystemOwned, signing: record.signing, capability: record.capability,
                    atLogin: record.atLogin,
                    targetPresence: PathObservation.observe(record.programPath, followingLinks: true),
                    recordIdentity: record.recordIdentity, namespace: record.namespace, runtimeState: "loaded",
                    rawTargetPath: record.rawTargetPath
                ))
            } else if presence.isUnknown {
                coverage = .unavailable(.launchdJob, "A reviewed background job could not be checked.")
            }
        }
        return RegistrationVerification(capability: .launchdJob, observedAt: observedAt,
                                        coverage: coverage, remaining: remaining,
                                        preserved: original.preserved,
                                        recoveryCopies: original.recoveryCopies)
    }

    static func registrationRoutes(plan: Plan,
                                   observations postChecks: [RegistrationVerification]) -> [RemovalFollowUp] {
        var followUps: [RemovalFollowUp] = []
        if postChecks.flatMap(\.remaining).contains(where: { $0.loginItemsFollowUp != nil }) {
            followUps.append(.loginItemsSettings)
        }
        if postChecks.contains(where: { $0.capability == .firewallEntry && !$0.remaining.isEmpty }) {
            followUps.append(.firewallSettings)
        }
        if postChecks.contains(where: { $0.capability == .configurationProfile && !$0.remaining.isEmpty }) {
            followUps.append(.deviceManagementSettings)
        }
        let extensions = postChecks.first { $0.capability == .systemExtension }?.remaining ?? []
        followUps.removeAll { $0 == .vendorUninstaller }
        if extensions
            .contains(where: { $0.runtimeState?.lowercased().contains("waiting to uninstall on reboot") == true }) {
            followUps.append(.restartForSystemExtension)
        } else if !extensions.isEmpty {
            followUps.append(.systemExtensionsSettings)
        }
        if plan.capabilityReport?.checks.contains(where: {
            $0.capability == .fileProvider && $0.declaration == .declared
        }) == true {
            followUps.append(.fileProviderOwner)
        }
        if postChecks.contains(where: { $0.capability == .appExtension && !$0.remaining.isEmpty }) {
            followUps.append(.systemExtensionsSettings)
        }
        return Array(Set(followUps)).sorted { $0.rawValue < $1.rawValue }
    }

    private struct RemovalFollowUps {
        let actions: [RemovalFollowUp]
        let privacyResetFailed: Bool
        let survivingExtensions: Set<String>?
    }

    private func removalFollowUps(
        plan: Plan, journal: JournalEntry?, postChecks: [RegistrationVerification]
    ) async -> RemovalFollowUps {
        let privacyResetFailed = journal != nil && plan.steps.contains { step in
            step.kind == .resetPrivacyGrants && journal?.stepOutcomes[step.index] != "ok"
        }
        let bundlePaths = plan.steps.filter { $0.executionPhase == .appBundle }.map(\.target)
            + [plan.intent.subjectIdentity.bundlePath].compactMap(\.self)
        let bundleStillPresent = bundlePaths.contains { FileManager.default.fileExists(atPath: $0) }
        let needsPrivacyFollowUp = privacyResetFailed
            && plan.intent.type == .uninstall && !bundleStillPresent
        let extensionCheck = postChecks.first { $0.capability == .systemExtension }
        let survivingExtensionIDs = extensionCheck?.coverage.available == true
            ? Set(extensionCheck?.remaining.map(\.identifier) ?? []) : nil
        var actions = plan.capabilityReport?.followUps(
            survivingSystemExtensionIDs: survivingExtensionIDs,
            privacyResetFailedAfterRemoval: needsPrivacyFollowUp
        ) ?? []
        if needsPrivacyFollowUp, !actions.contains(.restoreAppForPrivacyReset) {
            actions.append(.restoreAppForPrivacyReset)
        }
        return RemovalFollowUps(actions: actions, privacyResetFailed: privacyResetFailed,
                                survivingExtensions: survivingExtensionIDs)
    }

    private static func verificationReason(
        pathsRemaining: Set<String>, recorded: [String: String], staleRegistrations: [URL],
        privacyResetFailed: Bool,
        otherActionsFailed: Bool
    ) -> String? {
        let pathReason: String? = switch (pathsRemaining.count, staleRegistrations.isEmpty) {
        case (0, true):
            nil
        case (0, false):
            "Every file is gone, but macOS still has this app registered at "
                + staleRegistrations.map(\.path).joined(separator: ", ") + "."
        case (_, true):
            whyTheseRemain(pathsRemaining, recorded: recorded)
        default:
            whyTheseRemain(pathsRemaining, recorded: recorded)
                + " macOS also still has this app registered."
        }
        let privacyReason = privacyResetFailed ? "Privacy permissions were not reset." : nil
        let actionReason = otherActionsFailed ? "Some planned actions could not be completed." : nil
        let combined = [pathReason, privacyReason, actionReason].compactMap(\.self).joined(separator: "\n\n")
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

    /// Deletes for good what one removal put in the Trash, and nothing
    /// else there.
    ///
    /// Emptying the whole Trash would take the person's own files with
    /// Brim's. Only the items this removal recorded, and only while they
    /// are still in a Trash folder, are deleted, and the removal can no
    /// longer be put back afterwards. Registrations of bundles that are now
    /// gone are retracted, as they are when the Trash is emptied by hand.
    public func deleteFromTrash(planId: UUID) async throws {
        try beginOperation(planId: planId)
        defer { activePlans.remove(planId) }
        guard let journal = try await journalStore.load(planId: planId), journal.restoredAt == nil else {
            throw NSError(domain: "BrimService", code: 409, userInfo: [
                NSLocalizedDescriptionKey: "This removal has nothing left in the Trash."
            ])
        }
        let trashed = (journal.stepTrashedURLs ?? [:])
            .filter { journal.restoreOutcomes?[$0.key] != "ok" }
            .sorted { $0.key < $1.key }
        var failed: [String] = []
        for (_, url) in trashed {
            do {
                try SafeOps.deleteFromTrash(url)
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        await reconcileRegistrations()
        guard failed.isEmpty else {
            throw NSError(domain: "BrimService", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Could not delete \(failed.joined(separator: ", ")) from the Trash."
            ])
        }
    }

    public func undo(planId: UUID) async throws {
        try beginOperation(planId: planId)
        defer { activePlans.remove(planId) }
        let plan = try await planStore.load(planId: planId)
        guard let journal = try await journalStore.load(planId: planId) else {
            throw NSError(
                domain: "BrimService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No journal found for plan."]
            )
        }
        guard journal.restoredAt == nil else {
            throw NSError(domain: "BrimService", code: 409, userInfo: [
                NSLocalizedDescriptionKey: "This removal has already been put back."
            ])
        }
        let trashedURLs = journal.stepTrashedURLs ?? [:]

        // Refuse up front rather than restoring some steps and failing on the
        // rest. Two ways a plan cannot be undone: nothing was trashed to begin
        // with, or the Trash has since been emptied.
        guard plan.isReversible else {
            throw UndoError.planWasPermanent
        }

        let missing = plan.steps
            .filter { $0.effectiveDisposition == .trash && $0.kind != .unloadLaunchdJob }
            .compactMap { step -> String? in
                guard journal.restoreOutcomes?[step.index] != "ok" else { return nil }
                guard let trashed = trashedURLs[step.index] else { return nil }
                return PathExistence.exists(at: trashed) ? nil : step.target
            }
        guard missing.isEmpty else {
            throw UndoError.noLongerInTrash(targets: missing)
        }

        try await restoreFilesAndJobs(plan: plan, journal: journal)
        try await restoreApplicationRegistrations(plan: plan, journal: journal)

        // Restoring files does not erase execution receipts or prior checks.
        try await journalStore.markRestored(planId: planId, at: Date())
    }

    private func restoreFilesAndJobs(plan: Plan, journal: JournalEntry) async throws {
        let planId = plan.planId
        let trashedURLs = journal.stepTrashedURLs ?? [:]
        let fm = FileManager.default
        // 1. Restore items from Trash (atomically fails if path is re-occupied)
        let sortedSteps = plan.undoOrderedSteps
        for step in sortedSteps {
            if journal.restoreOutcomes?[step.index] == "ok" {
                continue
            }
            if step.kind == .unloadLaunchdJob {
                // An already-unloaded job must stay unloaded on recovery.
                let outcome = journal.stepOutcomes[step.index] ?? ""
                guard outcome == "ok" || outcome.hasPrefix("stopped_unverified:") else { continue }
                do {
                    try LaunchdExecution.verifyModification(step)
                    try await launchdRuntime.restore(step.target)
                    try await journalStore.recordRestoreOutcome(planId: planId, stepIndex: step.index, outcome: "ok")
                } catch {
                    try await journalStore.recordRestoreOutcome(planId: planId, stepIndex: step.index,
                                                                outcome: error.localizedDescription)
                    throw error
                }
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
                    try await journalStore.recordRestoreOutcome(planId: planId, stepIndex: step.index, outcome: "ok")
                } catch SafeOpsError.pathOccupied {
                    throw NSError(
                        domain: "BrimOps",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Path \(step.target) has been re-occupied."]
                    )
                }
            }
        }
    }

    private func restoreApplicationRegistrations(plan: Plan, journal: JournalEntry) async throws {
        let planId = plan.planId
        let trashedURLs = journal.stepTrashedURLs ?? [:]
        // Put the registration back with the bundle. The uninstall retracted
        // it deliberately, so restoring the files alone would leave a working
        // application macOS does not know about — no "Open With", no document
        // types, until something happens to rescan it.
        for step in plan.steps where step.kind == .unregisterLaunchServices {
            // An offline filesystem cannot restore the host Mac's registry.
            guard root.rootURL.standardizedFileURL.path == "/" else { continue }
            guard journal.stepOutcomes[step.index] == "ok",
                  let bundleStep = plan.steps.first(where: {
                      ($0.target == step.target || step.target.hasPrefix($0.target + "/"))
                          && [.trashPath, .removeLaunchdPlist].contains($0.kind)
                          && $0.effectiveDisposition == .trash && trashedURLs[$0.index] != nil
                  }), let fingerprint = bundleStep.targetFingerprint else { continue }
            if journal.restoreOutcomes?[step.index] == "ok" {
                continue
            }
            guard PathExistence.exists(atPath: step.target) else { continue }
            // Older plans retracted folders that only had an app's name, and
            // a folder has no registration to put back.
            guard ApplicationBundle.isBundle(atPath: step.target) else {
                try await journalStore.recordRestoreOutcome(planId: planId, stepIndex: step.index, outcome: "ok")
                continue
            }
            do {
                try SafeOps.verifyTargetFingerprint(targetPath: bundleStep.target,
                                                    expectedDev: fingerprint.dev, expectedIno: fingerprint.ino)
                let restoredRoot = URL(fileURLWithPath: bundleStep.target).resolvingSymlinksInPath().path
                let restoredApp = URL(fileURLWithPath: step.target).resolvingSymlinksInPath().path
                guard restoredApp == restoredRoot || restoredApp.hasPrefix(restoredRoot + "/"),
                      step.registrationBundleID.map({
                          CapabilitySearchScanner.applicationIdentifier(at: step.target) == $0
                      }) != false else {
                    throw NSError(domain: "BrimRegistration", code: 409, userInfo: [
                        NSLocalizedDescriptionKey: "The restored application's identity changed. "
                            + "Its registration was kept."
                    ])
                }
                try await LaunchServicesRegistration.registerBounded(bundlePath: step.target)
                try await journalStore.recordRestoreOutcome(planId: planId, stepIndex: step.index, outcome: "ok")
            } catch {
                try await journalStore.recordRestoreOutcome(planId: planId, stepIndex: step.index,
                                                            outcome: error.localizedDescription)
                throw error
            }
        }
    }

    /// Gives the executor a way to reach Brim's privileged daemon.
    ///
    /// Set by the application once, after the daemon reports itself
    /// ready. Nothing else in the service knows the daemon exists, which
    /// keeps the privileged path to one line in one place.
    public func usePrivilegedRemover(_ remover: (@Sendable (String) async -> String?)?) async {
        privilegedRemover = remover
        await executor.setPrivilegedRemover(remover)
    }

    /// Kept for updates, which replace a root-owned application the same
    /// way a removal sets one aside.
    var recoveryVerifier: (@Sendable () async throws -> [RecoveryCopy])?
    private var authenticatedPrivilegedPlans: [UUID: UUID] = [:]

    private var beginPrivilegedBatch: (@Sendable () async -> String?)?
    private var endPrivilegedBatch: (@Sendable () async -> Void)?

    public func usePrivilegedBatch(begin: (@Sendable () async -> String?)?,
                                   end: (@Sendable () async -> Void)?) async {
        beginPrivilegedBatch = begin
        endPrivilegedBatch = end
    }

    private var privilegedRemover: (@Sendable (String) async -> String?)?

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
        LaunchdRegistrationSurface(includeSystemJobs: false),
        FirewallSurface(), BackgroundItemSurface(),
        AppExtensionSurface(),
        SystemExtensionSurface(),
        PrivilegedHelperToolSurface(),
        BundlePluginSurface(),
        ShellProfileSurface(),
        KeychainSurface(),
        PrivacyGrantSurface()
    ]

    public func registrations() async -> RegistrationReport {
        let inventory = RegistrationInventory(surfaces: Self.everySurface)
        // Both questions at once. These were two sequential awaits, and
        // every surface answers them from the same read: asking what
        // `pluginkit` holds and then asking whether `pluginkit` answered
        // ran the subprocess twice, and the same doubling applied to the
        // Background Task Management store and every directory walk.
        return await inventory.snapshot(in: root)
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
    ///
    /// What was recorded when the step ran comes first. Working the reason
    /// out again afterwards from the folder's permissions is how three
    /// links the journal had marked `needs_helper_not_set_up` were reported
    /// as "macOS did not say why": the folder allowed the removal, so the
    /// after-the-fact reading had nothing to say.
    static func whyTheseRemain(
        _ paths: Set<String>,
        recorded: [String: String] = [:],
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
            let said = recorded[path].flatMap(Self.recordedReason)
                ?? "capability:\(capabilityForPath(path).rawValue)"
            let key = "\(folder)\u{0}\(said)"
            if names[key] == nil {
                order.append(key)
            }
            names[key, default: []].append((path as NSString).lastPathComponent)
        }

        let paragraphs = order.flatMap { key -> [String] in
            let parts = key.components(separatedBy: "\u{0}")
            let folder = parts[0]
            let said = parts[1]
            let these = names[key] ?? []

            // The folder is the subject wherever the folder is the reason,
            // so one sentence is right for one item and for fourteen. What
            // is left over is per item, and there the item is the subject.
            let reason: String
            if said.hasPrefix("capability:") {
                let capability = Capability(rawValue: String(said.dropFirst("capability:".count))) ?? .ok
                reason = RemovalCapability.folderExplanation(capability, folder: folder)
                    ?? RemovalCapability.explanation(capability)
                    ?? "Brim could not remove \(these.count == 1 ? "it" : "them"), and nothing was "
                    + "recorded to say why."
            } else {
                reason = said
            }
            // Where they are, whenever the reason has not already said.
            let list = these.joined(separator: ", ")
            return [reason, reason.contains(folder) ? list : "In \(folder): \(list)"]
        }

        return ([opening] + paragraphs).joined(separator: "\n\n")
    }

    /// What the journal recorded for each path that is still there.
    static func recordedOutcomes(
        plan: Plan, journal: JournalEntry?, remaining: Set<String>
    ) -> [String: String] {
        var recorded: [String: String] = [:]
        // One path can carry several steps: an app bundle is moved, and its
        // Launch Services record retracted after. The step that moves the
        // file answers for it. Reading the retraction's "ok" said WhatsApp's
        // bundle had been removed and written back, when it was never moved.
        for step in plan.steps where step.kind.targetIsPath && remaining.contains(step.target) {
            guard let outcome = journal?.stepOutcomes[step.index] else { continue }
            if step.kind == .unregisterLaunchServices, recorded[step.target] != nil {
                continue
            }
            let moves = step.kind != .unregisterLaunchServices
            if moves || recorded[step.target] == nil {
                recorded[step.target] = outcome
            }
        }
        return recorded
    }

    /// A journal outcome in the person's terms, or nil where there is
    /// nothing better to say than the folder's permissions.
    static func recordedReason(_ outcome: String) -> String? {
        if outcome == "needs_helper_not_set_up" {
            return "Administrator cleanup was unavailable, so protected items could not be moved. "
                + "Review the removal again in a signed copy of Brim."
        }
        if outcome.hasPrefix("helper_refused: ") {
            return "Brim's helper would not move this. "
                + outcome.dropFirst("helper_refused: ".count)
        }
        if outcome == "skipped_due_to_prior_failures" {
            return "Not attempted, because something before it in the same removal could not go."
        }
        // The folder's permissions may say nothing, as a sandboxed app's
        // temporary folder's did, and then "nothing was recorded to say why"
        // sat above a report saying macOS had refused it.
        if outcome == "refusedByOS" {
            return "macOS would not let Brim move this."
        }
        // The step worked and the file is back: something wrote it again
        // after it went. IINA's preferences were reported as "nothing was
        // recorded to say why" when the journal had recorded exactly that.
        if outcome == "ok" || outcome.hasPrefix("ok_but_preferences_may_return") {
            return "Brim removed this, and something wrote it back afterwards."
        }
        if outcome == "already_gone" || outcome == "unsupported_kind" {
            return nil
        }
        return "It could not be moved: \(outcome)"
    }

    /// Older callers may supply display text, but it has no authority.
    public func planToolCleanup(id: String, displayed _: String) async throws -> Plan {
        try await planToolCleanup(request: toolCleanupClient.request(id: id))
    }

    public func planToolCleanup(id: String, cachePath: URL) async throws -> Plan {
        try await planToolCleanup(request: toolCleanupClient.request(id: id, cachePath: cachePath))
    }

    private func planToolCleanup(request: ToolCleanupRequest) async throws -> Plan {
        let name = ToolCleanup.command(id: request.id.rawValue)?.displayed ?? "Tool cleanup"
        let intent = PlanIntent(type: .toolCleanup, subjectIdentity: Identity(bundleID: nil, name: name),
                                requesterKind: "ui", requesterIdentity: NSUserName(), toolCleanup: request)
        return try await plan(intent: intent)
    }

    private func makeToolCleanupPlan(_ intent: PlanIntent) async throws -> Plan {
        guard let request = intent.toolCleanup, intent.explicitTargets.isEmpty,
              intent.tickedByHand?.isEmpty != false
        else {
            throw ToolCleanup.CleanupError.bindingChanged
        }
        let binding = try await toolCleanupClient.prepare(request)
        let evidence = binding.displayed + "\nCache: " + binding.scope
            + "\nThe tool permanently removes cached packages. They may need to be downloaded again."
        let step = Step(index: 0, kind: .delegateToolCleanup, target: request.id.rawValue,
                        targetFingerprint: nil, tier: .A, evidence: evidence, expectedBytes: 0,
                        capability: .ok, reversible: false, costOfError: .low,
                        executionPhase: .auxiliary, disposition: .delete)
        return Plan(planId: UUID(), createdAt: Date(), engineVersion: EvidenceEngineRevision,
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString, intent: intent,
                    steps: [step], excludedItems: [], expectedTotalBytes: 0, toolCleanupBinding: binding)
    }

    public func developerCaches() async -> [DeveloperCache] {
        await DeveloperCacheScanner(home: root.url(for: .userHomeDotFolders),
                                    darwinCache: root.url(for: .darwinUserCache)).scan()
    }

    public func sampleEnergy() async -> EnergySampleResult {
        await EnergySampler().sample()
    }

    public func volumes() async -> [VolumeAccount] {
        await VolumeAccountant().accounts()
    }

    public func installedApplications() async throws -> [InstalledApplication] {
        try Task.checkCancellation()
        let applications = await applicationInventoryRead().value
        try Task.checkCancellation()

        // Every enumeration is written down, so "what changed" is the
        // last two snapshots differenced and nothing has to watch for
        // installations. Best effort: a history that could not be
        // written must not stop the list being returned.
        await recordSnapshot(of: applications)
        return await withInstallDates(applications)
    }

    public func installRecords() async -> [InstallRecord] {
        await (try? index?.installRecords()) ?? []
    }

    /// Apps and Updates can open together. Share their active read, then drop
    /// it so a later check always describes the filesystem again. The service
    /// owns the task; cancelling one waiter cannot stop the other one's read.
    func applicationInventoryRead() -> Task<[InstalledApplication], Never> {
        if let applicationInventoryTask {
            return applicationInventoryTask
        }
        let task = Task {
            // Recovery can put a staged application back. Finish it before
            // either caller describes the installed bundles, and keep the
            // interrupted results until Updates has had a chance to show them.
            let interrupted: [String: String] = if let updateRecoveryReader {
                await updateRecoveryReader()
            } else if root.rootURL.standardizedFileURL.path == "/" {
                UpdateInstaller.recoverInterrupted(
                    in: Self.updatesDirectory.appendingPathComponent("Downloads")
                )
            } else {
                [:]
            }
            pendingInterruptedUpdates.merge(interrupted) { _, newer in newer }
            let applications: [InstalledApplication] = if let applicationInventoryReader {
                await applicationInventoryReader()
            } else {
                await ApplicationInventory(root: root).installedApplications()
            }
            applicationInventoryTask = nil
            return applications
        }
        applicationInventoryTask = task
        return task
    }

    /// Injected reads keep concurrency tests away from the person's update
    /// recovery directory and make overlapping enumerations reproducible.
    func useApplicationInventory(
        reader: @escaping @Sendable () async -> [InstalledApplication],
        recovery: @escaping @Sendable () async -> [String: String]
    ) {
        applicationInventoryReader = reader
        updateRecoveryReader = recovery
    }

    /// Each application's latest recorded installation. A return after a
    /// snapshot confirmed its absence starts another installation period.
    ///
    /// First appearing is not the same as arriving. When the inventory
    /// began listing the apps inside Xcode, Icon Composer, FileMerge and
    /// five more were in the next snapshot and not the one before, and
    /// Home announced them all as installed today, years after Xcode put
    /// them there. So an appearance counts only when nothing shows the
    /// bundle was already on the disk at Brim's previous look: Spotlight's
    /// date added can move later on an update but never earlier, so a date
    /// before that look is proof. An app inside another arrives with its
    /// host and takes the host's date.
    private func withInstallDates(_ applications: [InstalledApplication]) async -> [InstalledApplication] {
        let windows = await (try? index?.appearanceWindows()) ?? [:]
        let byPath = Dictionary(applications.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        func arrival(_ application: InstalledApplication) -> Date? {
            if let host = application.hostURL {
                return byPath[host.path].flatMap(arrival)
            }
            guard let bundleID = application.identity.bundleID, let window = windows[bundleID] else { return nil }
            if !window.isReinstallation, let added = window.addedAt, added < window.previousLook {
                return nil
            }
            return window.seen
        }
        return applications.map { application in
            var dated = application
            dated.installedAt = arrival(application)
            return dated
        }
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
                sizeBytes: application.bundleSizeBytes,
                addedAt: application.addedAt,
                lastUsedAt: application.lastOpened,
                names: application.identity.ownNames + application.identity.derivedNames
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

    /// Whether each application has a newer version, from its own source.
    ///
    /// Reaches the network: Apple's catalogue, the feeds applications read
    /// themselves, and Homebrew's public catalogue revalidated for this check.
    public func checkForUpdates() async -> UpdateCheck {
        let applications = await applicationInventoryRead().value
        let interrupted = pendingInterruptedUpdates
        pendingInterruptedUpdates = [:]
        var check = await UpdateFinder(catalogueDirectory: Self.updatesDirectory.appendingPathComponent("Catalogue"))
            .check(applications)
        check.recent = await recentUpdates(applications)
        check.interrupted = interrupted
        return check
    }

    /// Applications that took a new version in the last two weeks.
    ///
    /// When is read off the bundle: the App Store rewrites an app's receipt
    /// when it updates it, and anything else that puts a new copy in place
    /// sets the date it was added. Only an app Brim's snapshots saw at an
    /// older version before then counts, so a fresh install is not called
    /// an update.
    func recentUpdates(_ applications: [InstalledApplication], now: Date = Date()) async -> [RecentUpdate] {
        guard let index else { return [] }
        let window = now.addingTimeInterval(-14 * 86400)
        var recent: [RecentUpdate] = []
        for application in applications where !application.isSystemProtected && application.enclosingApp == nil {
            guard let bundleID = application.identity.bundleID else { continue }
            let receipt = application.url.appendingPathComponent("Contents/_MASReceipt/receipt")
            let receiptDate = (try? receipt.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let added = (try? application.url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?
                .addedToDirectoryDate
            guard let changed = [receiptDate, added].compactMap(\.self).max(), changed > window else { continue }
            let version = UpdateInstaller.shortVersion(of: application.url)
            guard !version.isEmpty,
                  let before = try? await index.version(of: bundleID, before: changed),
                  VersionOrder.isNewer(version, than: before)
            else { continue }
            recent.append(RecentUpdate(name: application.name, appURL: application.url, fromVersion: before,
                                       toVersion: version, updatedAt: changed))
        }
        return recent.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Puts one update in place. Homebrew updates what it installed; the
    /// rest Brim downloads, checks and swaps, or hands to Installer.
    public func installUpdate(
        _ update: AppUpdate, progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async -> UpdateOutcome {
        switch update.route {
        case .homebrew:
            guard case let .homebrew(cask) = update.origin else { return .failed("Homebrew does not know this app.") }
            if let problem = await UpdateChecker().upgradeCask(cask) {
                return .failed(problem)
            }
            let info = NSDictionary(contentsOf: update.appURL.appendingPathComponent("Contents/Info.plist"))
            return .installed(version: info?["CFBundleShortVersionString"] as? String ?? update.latestVersion)
        case .appStore, .website:
            return .failed("This update is installed from its page.")
        case .replace, .installer:
            return await UpdateInstaller(
                workspace: Self.updatesDirectory.appendingPathComponent("Downloads"),
                remover: { [privilegedRemover, beginPrivilegedBatch, endPrivilegedBatch] path in
                    if let problem = await beginPrivilegedBatch?() {
                        return problem
                    }
                    let problem = await privilegedRemover?(path)
                        ?? (privilegedRemover == nil ? "Administrator cleanup is unavailable." : nil)
                    await endPrivilegedBatch?()
                    return problem
                }
            ).install(update, progress: progress)
        }
    }

    static var updatesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.sabharishhh.brim/Updates", isDirectory: true)
    }

    /// Casks Homebrew still tracks whose application is gone.
    ///
    /// Found by subtracting what is installed from what Homebrew lists.
    /// Nothing else looks here: the application is in the Trash, so every
    /// scan of the disk says it is gone, while Homebrew goes on offering
    /// to upgrade it.
    func orphanedCaskNames() async -> Set<String> {
        let inventory = await Self.homebrewInventory(in: root)
        guard inventory.completeness.isComplete else { return [] }
        let installations = Dictionary(grouping: inventory.installations, by: \.token)
        return Set(installations.compactMap { token, applications in
            let allAbsent = applications.allSatisfy { installation in
                var info = stat()
                guard lstat(installation.applicationPath, &info) != 0 else { return false }
                return errno == ENOENT || errno == ENOTDIR
            }
            return allAbsent ? token : nil
        })
    }

    /// Installations, removals and updates observed in the past week.
    ///
    /// Empty on a first run, which is the honest answer: there is
    /// nothing to compare against, and inventing a list of "new"
    /// applications the first time somebody opens Brim would make every
    /// later list untrustworthy.
    public func whatChanged() async -> InstallHistory {
        guard let index else { return InstallHistory(changes: [], snapshots: 0) }
        let now = Date()
        return await InstallHistory(
            changes: (try? index.recentChanges(since: now.addingTimeInterval(-7 * 86400), until: now)) ?? [],
            snapshots: (try? index.snapshotCount()) ?? 0
        )
    }

    public func leftovers() async throws -> [Leftover] {
        try Task.checkCancellation()
        if let leftoversTask {
            let result = try await leftoversTask.value
            try Task.checkCancellation()
            return result
        }
        // Review and Storage can request the same read concurrently. Share only
        // in-flight work; a later rescan always reads the filesystem again.
        let task = Task { try await self.scanLeftovers() }
        leftoversTask = task
        defer { leftoversTask = nil }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    private func scanLeftovers() async throws -> [Leftover] {
        // A registration whose program has gone names an owner that was
        // recorded present and is not there now — the spec's definition of
        // orphaned, and the thing a user actually notices as "I uninstalled
        // this and it is still here". The sweep already enumerates these.
        var staleRegistrationOwners: [String: String] = [:]
        let inventory = RegistrationInventory(surfaces: Self.everySurface)
        for registration in await inventory.all(in: root) where registration.isStale && !registration.isSystemOwned {
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
        let orphanCasks = await orphanedCaskNames()

        // An app Brim's own snapshots saw installed and no longer see is the
        // plainest record there is that it was here and has gone. Teams and
        // Microsoft AutoUpdate were removed, Home said so, and what they left
        // was still listed as owner unknown.
        let removedApps = await (try? index?.removedApplications()) ?? [:]
        let recorded = await (try? index?.recordedNames()) ?? [:]
        for (id, seen) in removedApps where staleRegistrationOwners[id] == nil {
            let name = recorded[id.lowercased()] ?? id
            staleRegistrationOwners[id] = "Brim saw \(name) installed until "
                + seen.formatted(.dateTime.day().month(.abbreviated)) + "."
        }

        let scanner = LeftoversScanner(
            root: root,
            launchServicesLookup: { try LaunchServicesRegistration.checkedApplicationURLs(forBundleID: $0) },
            staleRegistrationOwners: staleRegistrationOwners,
            homebrewOrphans: orphanCasks,
            claimedPaths: DeveloperCacheScanner
                .claimedPaths(home: root.url(for: .userLibrary).deletingLastPathComponent()),
            removedApplications: removedApps,
            protectedAppURL: brimAppURL,
            // A week, and only on the real disk: a fixture tree is written
            // moments before it is scanned, so every folder in it is new.
            inUseWithin: root.rootURL.path == "/" ? 7 * 24 * 60 * 60 : nil
        )
        var knownPastBundleIDs = Set(removedApps.keys)
        // What Brim has seen applications called. Without it a leftover
        // was named from its identifier alone, so Teams' would read "Teams2"
        // although Brim had recorded "Microsoft Teams" for weeks.
        var knownNames = await (try? index?.recordedNames()) ?? [:]
        var knownAliases = await (try? index?.recordedAliases()) ?? [:]
        var knownIdentities: [Identity] = []
        let entries = try await ledgerStore.allEntries()
        for entry in entries {
            if let plan = try? await planStore.load(planId: entry.planId) {
                let subject = plan.intent.subjectIdentity
                if let bid = subject.bundleID {
                    knownPastBundleIDs.insert(bid)
                    knownNames[bid.lowercased()] = subject.name
                    knownAliases[bid.lowercased(), default: []] += subject.ownNames + subject.derivedNames
                    if plan.intent.type == .uninstall, subject.identitySurface != nil {
                        knownIdentities.append(subject)
                    }
                }
            }
        }

        var found = try await scanner.scanLeftovers(
            knownPastBundleIDs: knownPastBundleIDs, knownNames: knownNames, knownAliases: knownAliases,
            knownIdentities: knownIdentities
        )
        found += await recordedRemnants(listed: Set(found.map(\.url.path)))
        return await attachingReplacements(to: found) + recoveryLeftovers()
    }

    /// Says which installed app replaced a removed one, where that is
    /// proven: a record of where the removed app was, an installed app with
    /// another identifier at exactly that path, and the same developer.
    private func attachingReplacements(to leftovers: [Leftover]) async -> [Leftover] {
        let owners = Set(leftovers.compactMap { $0.potentialOwner?.bundleID })
        guard !owners.isEmpty else { return leftovers }
        let installed: [Replacement.Installed] = InstalledBundleInventory.read(in: root).bundles.compactMap { url in
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            guard let id = info?["CFBundleIdentifier"] as? String else { return nil }
            return Replacement.Installed(bundleID: id, name: url.deletingPathExtension().lastPathComponent,
                                         path: url.path)
        }
        let seen = await (try? index?.lastBundlePaths(of: Array(owners))) ?? [:]
        var replacements: [String: Replacement] = [:]
        for owner in owners {
            let registered = LaunchServicesRegistration.registeredApplicationURLs(forBundleID: owner).map(\.path)
            let places = [seen[owner]].compactMap(\.self) + registered
            if let found = Replacement.find(removed: owner, formerPaths: places, installed: installed) {
                replacements[owner] = found
            }
        }
        guard !replacements.isEmpty else { return leftovers }
        return leftovers.map { item in
            guard let owner = item.potentialOwner?.bundleID, let found = replacements[owner] else { return item }
            var copy = item
            copy.replacedBy = found
            return copy
        }
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
                  journal.restoredAt == nil
            else { continue }

            let trashedURLs = (journal.stepTrashedURLs ?? [:]).filter {
                journal.restoreOutcomes?[$0.key] != "ok"
            }
            let pendingRegistration = plan.steps.contains {
                Self.registrationCanBeRestored($0, plan: plan, journal: journal)
            }
            guard !trashedURLs.isEmpty || pendingRegistration else { continue }

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

    /// A registration receipt alone cannot put anything back. Its declaration
    /// or the owned application copy must still support the existing undo route.
    private static func registrationCanBeRestored(_ step: Step, plan: Plan, journal: JournalEntry) -> Bool {
        guard journal.restoreOutcomes?[step.index] != "ok" else { return false }
        let outcome = journal.stepOutcomes[step.index] ?? ""
        switch step.kind {
        case .unloadLaunchdJob:
            return launchdJobCanBeRestored(step, plan: plan, journal: journal, outcome: outcome)
        case .unregisterLaunchServices:
            guard outcome == "ok",
                  let removal = plan.steps.first(where: {
                      ($0.target == step.target || step.target.hasPrefix($0.target + "/"))
                          && [.trashPath, .removeLaunchdPlist].contains($0.kind)
                          && $0.effectiveDisposition == .trash && journal.stepTrashedURLs?[$0.index] != nil
                  }), let fingerprint = removal.targetFingerprint,
                  let saved = journal.stepTrashedURLs?[removal.index] else { return false }
            let restored = journal.restoreOutcomes?[removal.index] == "ok"
            let bundleRoot = restored ? URL(fileURLWithPath: removal.target) : saved
            do {
                try SafeOps.verifyTargetFingerprint(targetPath: bundleRoot.path,
                                                    expectedDev: fingerprint.dev, expectedIno: fingerprint.ino)
            } catch { return false }
            let relative = String(step.target.dropFirst(removal.target.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let bundle = relative.isEmpty ? bundleRoot : bundleRoot.appendingPathComponent(relative)
            let rootPath = bundleRoot.resolvingSymlinksInPath().path
            let bundlePath = bundle.resolvingSymlinksInPath().path
            guard bundlePath == rootPath || bundlePath.hasPrefix(rootPath + "/"),
                  PathExistence.exists(at: bundle) else { return false }
            return step.registrationBundleID.map {
                CapabilitySearchScanner.applicationIdentifier(at: bundle.path) == $0
            } ?? true
        default:
            return false
        }
    }

    private static func launchdJobCanBeRestored(
        _ step: Step, plan: Plan, journal: JournalEntry, outcome: String
    ) -> Bool {
        guard outcome == "ok" || outcome.hasPrefix("stopped_unverified:") else {
            return false
        }
        let declaration: String
        if PathExistence.exists(atPath: step.target) {
            declaration = step.target
        } else if let removal = plan.steps.first(where: { removal in
            removal.kind == .removeLaunchdPlist && removal.target == step.target
                && removal.effectiveDisposition == .trash
                && journal.restoreOutcomes?[removal.index] != "ok"
                && journal.stepTrashedURLs?[removal.index] != nil
        }), let saved = journal.stepTrashedURLs?[removal.index] {
            declaration = saved.path
        } else {
            return false
        }
        do {
            try LaunchdExecution.verifyModification(step, at: declaration)
            return true
        } catch {
            return false
        }
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
    public func reconcileRegistrations() async {
        let fm = FileManager.default

        for entry in await (try? ledgerStore.allEntries()) ?? [] {
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

            guard let candidates = try? LaunchServicesRegistration.checkedApplicationURLs(forBundleID: bundleID) else {
                continue
            }
            let registered = Set(candidates.map(\.standardizedFileURL.path))
            for url in vanished where registered.contains(url.standardizedFileURL.path) {
                guard PathObservation.observe(url.path).isAbsent else { continue }
                do {
                    try await LaunchServicesRegistration.unregisterBounded(bundlePath: url.path)
                } catch {
                    // A refused maintenance command is not a completed action.
                    continue
                }
            }
        }
    }
}
