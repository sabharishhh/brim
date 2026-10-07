import BrimCore
import BrimOps
import Foundation
import os

// swiftformat:disable wrapMultilineStatementBraces
private let log = BrimLog.make("executor")

public actor Executor {
    private let journalStore: JournalStore
    private let fm = FileManager.default
    private let toolCleanupClient: ToolCleanup.Client
    private let launchdRuntime: LaunchdRuntimeClient

    /// Removes something this process cannot reach, through administrator
    /// cleanup. Nil when this copy of Brim has none, which is not an error:
    /// the step then records that it needed it, and the plan says so rather
    /// than half succeeding.
    ///
    /// Injected rather than imported so the executor knows nothing about
    /// how root is reached, and so a test can stand in for root.
    private var privilegedRemover: (@Sendable (String) async -> String?)?

    /// Forgets an installer receipt through administrator cleanup. Nil
    /// without it: receipts live in a folder that belongs to root, so the
    /// step then tries the bounded `pkgutil` route and records what it got.
    private var privilegedReceiptForgetter: (@Sendable (String) async -> String?)?

    private var recoveryRemover: (@Sendable (String, TargetFingerprint) async -> String?)?

    func setRecoveryRemover(_ remover: (@Sendable (String, TargetFingerprint) async -> String?)?) {
        recoveryRemover = remover
    }

    public init(
        journalStore: JournalStore,
        toolCleanupClient: ToolCleanup.Client = .init(),
        launchdRuntime: LaunchdRuntimeClient = .init()
    ) {
        self.launchdRuntime = launchdRuntime
        self.toolCleanupClient = toolCleanupClient
        self.journalStore = journalStore
    }

    public func execute(plan: Plan) async throws -> JournalEntry {
        let volumes = Self.targetVolumes(for: plan.steps)
        let freeBefore = volumes.flatMap { Self.sampleFreeSpace(on: $0) }

        // Create initial journal
        var journal = JournalEntry(
            planId: plan.planId,
            startedAt: Date(),
            status: .pending,
            freeSpaceBefore: freeBefore
        )
        try await journalStore.write(entry: journal)

        let sortedSteps = plan.executionOrderedSteps

        var hasFailures = false
        // What keeps the app bundle in place. Every failure does, except
        // macOS refusing an ordinary support file: that says nothing about
        // whether the app can go. WhatsApp's removal left the whole app
        // because macOS would not move its extension's temporary folder.
        var blocksBundle = false
        var stoppedJobs = Set<String>()
        var clearedPreferenceFiles: [String] = []
        defer {
            // Not awaited: the daemon's empty copy arrives seconds after
            // the removal has finished, and nobody should wait for it.
            if !clearedPreferenceFiles.isEmpty {
                let files = clearedPreferenceFiles
                Task.detached { await PreferenceDomains.removeEmptyWriteBack(at: files) }
            }
        }

        for step in sortedSteps {
            if blocksBundle {
                if step.executionPhase == .appBundle {
                    journal.stepOutcomes[step.index] = "skipped_due_to_prior_failures"
                    continue
                }
            }

            // Steps whose target is an identifier rather than a path are not
            // subject to the "already gone" check; a bundle id is not a file,
            // and skipping it here would silently drop the reset.
            //
            // Unregistering is exempt for the opposite reason: its target is
            // a path, but the whole point is that the bundle is already gone
            // while its registration is not.
            // `PathExistence`, not `fileExists`: the latter follows a
            // symlink, so a step to remove a broken one was recorded as
            // `already_gone` while the link stayed on the disk.
            if step.kind.targetIsPath,
               step.kind != .unregisterLaunchServices,
               RecoveryCopy.identifier(for: step.target) == nil,
               PathObservation.observe(step.target).isAbsent {
                journal.stepOutcomes[step.index] = "already_gone"
                continue
            }

            do {
                if step.kind == .unloadLaunchdJob || step.kind == .removeLaunchdPlist {
                    try LaunchdExecution.verifyModification(step)
                }
                if step.kind == .trashPathPrivileged, step.effectiveDisposition == .delete {
                    try await Self.removeRecoveryCopy(step, using: recoveryRemover)
                    journal.stepOutcomes[step.index] = "ok"
                } else if step.kind == .trashPathPrivileged {
                    // Something in a folder that belongs to root. The
                    // administrator process applies its own rules and moves
                    // the file to a holding folder rather than deleting it.
                    // Brim cannot put it back from there.
                    guard let privilegedRemover else {
                        journal.stepOutcomes[step.index] = "needs_helper_not_set_up"
                        hasFailures = true
                        blocksBundle = true
                        continue
                    }
                    if let refusal = await privilegedRemover(step.target) {
                        journal.stepOutcomes[step.index] = "helper_refused: \(refusal)"
                        hasFailures = true
                        blocksBundle = true
                    } else {
                        journal.stepOutcomes[step.index] = "ok"
                    }
                } else if step.kind == .trashPath || step.kind == .removeLaunchdPlist {
                    if step.kind == .removeLaunchdPlist, !stoppedJobs.contains(step.target) {
                        throw NSError(domain: "BrimLaunchd", code: 3, userInfo: [
                            NSLocalizedDescriptionKey: "The job was not confirmed stopped. Its declaration was kept."
                        ])
                    }
                    guard let fp = step.targetFingerprint else {
                        throw NSError(
                            domain: "BrimSecurity",
                            code: 401,
                            userInfo: [NSLocalizedDescriptionKey: "Missing target fingerprint for secure deletion"]
                        )
                    }

                    // Preferences are owned by cfprefsd, not by the file.
                    // Unlinking the plist and leaving the daemon holding
                    // the domain means the daemon writes it straight back
                    // out, and the person watches a setting they removed
                    // reappear. Told first, so the cache is invalid before
                    // the file goes.
                    //
                    // Best effort on purpose: failing to invalidate a cache
                    // is not a reason to abandon an uninstall, and the
                    // journal records it either way.
                    var preferenceDomainForgotten: Bool?
                    if let domain = PreferenceDomains.domain(forPlistAt: step.target) {
                        preferenceDomainForgotten = PreferenceDomains.forget(domain)
                        clearedPreferenceFiles.append(step.target)
                    }

                    switch step.effectiveDisposition {
                    case .trash:
                        let resultingURL = try SafeOps.trashItem(
                            targetPath: step.target,
                            expectedDev: fp.dev,
                            expectedIno: fp.ino
                        )
                        if let url = resultingURL {
                            if journal.stepTrashedURLs == nil {
                                journal.stepTrashedURLs = [:]
                            }
                            journal.stepTrashedURLs?[step.index] = url
                        }
                    case .delete:
                        // Permanent: no trashed URL is recorded, so undo knows
                        // there is nothing to put back for this step.
                        try SafeOps.deleteItem(targetPath: step.target, expectedDev: fp.dev, expectedIno: fp.ino)
                    }
                    if preferenceDomainForgotten == false {
                        journal.stepOutcomes[step.index] =
                            "ok_but_preferences_may_return: the file is gone, and macOS's "
                                + "preference daemon would not let go of the settings, so they "
                                + "can come back until you log out."
                    } else {
                        journal.stepOutcomes[step.index] = "ok"
                    }
                } else if step.kind == .resetPrivacyGrants {
                    // Must run while the bundle is still on disk; the plan's
                    // privacyReset phase sorts ahead of every removal so that
                    // holds. The target is a bundle identifier, not a path.
                    //
                    // Recorded but never fatal: the user asked for the app to
                    // be removed, and refusing to remove it because a grant
                    // could not be cleared would be the wrong trade. The
                    // outcome is journalled so the result can say so.
                    do {
                        try await Self.resetPrivacy(step: step, plan: plan)
                        journal.stepOutcomes[step.index] = "ok"
                    } catch {
                        journal.stepOutcomes[step.index] = "privacy_grants_not_cleared: \(error.localizedDescription)"
                    }
                } else if step.kind == .delegateToolCleanup {
                    // The target names which cleanup to run, never the
                    // command. The vocabulary forbids a caller-supplied
                    // command string, and this is the step most tempted by
                    // one.
                    do {
                        guard plan.intent.type == .toolCleanup,
                              let request = plan.intent.toolCleanup, let binding = plan.toolCleanupBinding,
                              request.id.rawValue == step.target
                        else {
                            throw ToolCleanup.CleanupError.bindingChanged
                        }
                        try await toolCleanupClient.run(binding, request: request)
                        journal.stepOutcomes[step.index] = "ok"
                    } catch let error as ToolCleanup.CleanupError {
                        hasFailures = true
                        journal.stepOutcomes[step.index] = "\(error.outcomeCode): \(error.localizedDescription)"
                    } catch {
                        hasFailures = true
                        journal.stepOutcomes[step.index] =
                            "cleanup_execution_failed: \(error.localizedDescription)"
                    }
                } else if step.kind == .unregisterLaunchServices {
                    // Only the path the app was installed at. A bundle that
                    // went to the Trash keeps its name, so Launch Services
                    // registers it there, but that record is *accurate*:
                    // the app really is in the Trash, and macOS does the same
                    // for any app dragged there by hand. Retracting it is the
                    // Trash's lifecycle, not this step's, and racing Launch
                    // Services to do it here loses: `lsregister -u` exits
                    // non-zero because the record does not exist yet, and the
                    // daemon creates it a moment later.
                    //
                    // Recorded, never fatal, for the same reason as the
                    // privacy reset. The files are already gone; refusing the
                    // whole uninstall over a registration would be the wrong
                    // trade, and the journal says what happened either way.
                    journal.stepOutcomes[step.index] = await Self.unregisterComponent(
                        step: step, plan: plan, outcomes: journal.stepOutcomes
                    )
                } else if step.kind == .unloadLaunchdJob {
                    let receipt = try await LaunchdExecution.stop(step.target, runtime: launchdRuntime)
                    journal.stepOutcomes[step.index] = receipt.outcome
                    if receipt.verified {
                        stoppedJobs.insert(step.target)
                    } else {
                        hasFailures = true
                        blocksBundle = true
                    }
                } else if step.kind == .clearImmutableFlag {
                    // Locked files used to vanish from the plan: the safety
                    // checker refused them and said nothing, so a person saw
                    // a shorter list rather than a reason. Now it is a step,
                    // and one the review sheet shows before it happens.
                    guard let fp = step.targetFingerprint else {
                        throw NSError(
                            domain: "BrimSecurity", code: 401,
                            userInfo: [NSLocalizedDescriptionKey:
                                "Missing target fingerprint for unlocking"]
                        )
                    }
                    do {
                        try ImmutableFlag.clear(
                            atPath: step.target, expectedDev: fp.dev, expectedIno: fp.ino
                        )
                        journal.stepOutcomes[step.index] = "ok"
                    } catch {
                        // Fatal for the plan: whatever came next wanted this
                        // file unlocked, and a removal that carries on will
                        // fail in a less legible way.
                        journal.stepOutcomes[step.index] =
                            "still_locked: \(error.localizedDescription)"
                        hasFailures = true
                        blocksBundle = true
                    }
                } else if step.kind == .revealVendorUninstaller {
                    // Brim opens Finder and stops. It never runs a vendor's
                    // uninstaller: that is somebody else's executable doing
                    // who knows what, and the point of the step is that the
                    // person decides.
                    do {
                        try VendorUninstaller.reveal(at: step.target)
                        journal.stepOutcomes[step.index] = "ok"
                    } catch {
                        journal.stepOutcomes[step.index] =
                            "could_not_reveal: \(error.localizedDescription)"
                    }
                } else if step.kind == .forgetReceipt {
                    guard plan.survivingCopies?.isEmpty != false,
                          let payload = plan.receiptPayloads?[step.target], !payload.isEmpty,
                          payload.allSatisfy({ PathObservation.observe($0).isAbsent })
                    else {
                        journal.stepOutcomes[step.index] = "receipt_kept_for_remaining_payload"
                        continue
                    }
                    // Deletes no files. It removes the installer's record,
                    // so `pkgutil --pkgs` stops listing software that is
                    // gone and an installer cannot offer to repair it back
                    // into existence. The target is a package identifier.
                    if let forgetter = privilegedReceiptForgetter {
                        if let refusal = await forgetter(step.target) {
                            journal.stepOutcomes[step.index] = "receipt_remains: \(refusal)"
                        } else {
                            journal.stepOutcomes[step.index] = "ok"
                        }
                    } else {
                        do {
                            try await PackageReceipts.forgetBounded(packageID: step.target)
                            journal.stepOutcomes[step.index] = "ok"
                        } catch {
                            // Recorded, never fatal. The files are gone; the
                            // record outliving them is worth reporting and
                            // not worth abandoning the removal over.
                            journal.stepOutcomes[step.index] =
                                "receipt_remains: \(error.localizedDescription)"
                        }
                    }
                } else {
                    journal.stepOutcomes[step.index] = "unsupported_kind"
                    hasFailures = true
                    blocksBundle = true
                }
            } catch let SafeOpsError.failedToRename(err) where err == EPERM,
                        let SafeOpsError.failedToUnlink(err) where err == EPERM {
                journal.stepOutcomes[step.index] = "refusedByOS"
                hasFailures = true
                if !Self.isSupportFile(step) {
                    blocksBundle = true
                }
            } catch {
                let nsErr = error as NSError
                if (nsErr.domain == NSCocoaErrorDomain && nsErr.code == 513) || nsErr
                    .code == EPERM || (nsErr.domain == NSPOSIXErrorDomain && nsErr.code == EPERM) {
                    journal.stepOutcomes[step.index] = "refusedByOS"
                    if !Self.isSupportFile(step) {
                        blocksBundle = true
                    }
                } else {
                    journal.stepOutcomes[step.index] = error.localizedDescription
                    blocksBundle = true
                }
                hasFailures = true
            }

            // Record after each step to handle crashes mid-way.
            // AUDIT H-6 FIX: Swallow write errors to avoid aborting execution.
            do {
                try await journalStore.write(entry: journal)
            } catch {
                // Swallowed so a write failure cannot abort a removal the
                // person asked for, which means this is the only trace of
                // it. The journal is what reconciles a crash mid-apply, so
                // one that stopped being written is the first thing to look
                // for when a relaunch cannot make sense of an open run.
                // One literal: `OSLogMessage` is built by the compiler from
                // an interpolated string, so a concatenation will not type
                // check here.
                log.error("could not write the journal at step \(step.index): \(error.localizedDescription)")
            }
        }

        let freeAfter = volumes.flatMap { Self.sampleFreeSpace(on: $0) }
        journal.freeSpaceAfter = freeAfter
        journal.status = hasFailures ? .partial : .completed
        try await journalStore.write(entry: journal)

        return journal
    }
}

public extension Executor {
    func setPrivilegedRemover(_ remover: (@Sendable (String) async -> String?)?) {
        privilegedRemover = remover
    }

    /// An ordinary file or folder outside the app, moved to the Trash. A
    /// refusal there leaves that item behind and nothing else at risk.
    internal static func isSupportFile(_ step: Step) -> Bool {
        step.kind == .trashPath && step.executionPhase == .auxiliary
    }

    func setPrivilegedReceiptForgetter(_ forgetter: (@Sendable (String) async -> String?)?) {
        privilegedReceiptForgetter = forgetter
    }
}
