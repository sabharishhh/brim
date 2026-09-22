import Foundation
import BrimCore
import BrimOps

public actor Executor {
    private let journalStore: JournalStore
    private let fm = FileManager.default

    /// Removes something this process cannot reach, by asking Brim's
    /// privileged daemon. Nil when no daemon is set up, which is the
    /// normal state and is not an error: the step then records that it
    /// needed one, and the plan says so rather than half succeeding.
    ///
    /// Injected rather than imported so the executor keeps knowing
    /// nothing about XPC, and so a test can stand in for root.
    private var privilegedRemover: (@Sendable (String) async -> String?)?

    /// Forgets an installer receipt, by asking the daemon. Nil when no
    /// daemon is set up: receipts live in a folder that belongs to root,
    /// so without one the step records that it needed help rather than
    /// failing with a permission error nobody can act on.
    private var privilegedReceiptForgetter: (@Sendable (String) async -> String?)?

    public func setPrivilegedRemover(_ remover: (@Sendable (String) async -> String?)?) {
        self.privilegedRemover = remover
    }

    public func setPrivilegedReceiptForgetter(_ forgetter: (@Sendable (String) async -> String?)?) {
        self.privilegedReceiptForgetter = forgetter
    }
    
    public init(journalStore: JournalStore) {
        self.journalStore = journalStore
    }


    public func execute(plan: Plan) async throws -> JournalEntry {
        let rootPath = plan.steps.first?.target ?? "/" // fallback
        // M3: Collect unique volume paths and sum their free space
        var volumeSet = Set<String>()
        for step in plan.steps {
            var statBuf = statfs()
            if statfs(step.target, &statBuf) == 0 {
                let mntonname = withUnsafePointer(to: statBuf.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { ptr in String(cString: ptr) }
                }
                volumeSet.insert(mntonname)
            } else if statfs(URL(fileURLWithPath: step.target).deletingLastPathComponent().path, &statBuf) == 0 {
                let mntonname = withUnsafePointer(to: statBuf.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { ptr in String(cString: ptr) }
                }
                volumeSet.insert(mntonname)
            }
        }
        
        var totalFreeBefore: Int64 = 0
        for vol in volumeSet {
            if let free = try? SafeOps.freeSpace(onPath: vol) { totalFreeBefore += free }
        }
        let freeBefore: Int64? = totalFreeBefore > 0 ? totalFreeBefore : (try? SafeOps.freeSpace(onPath: rootPath))
        
        // Create initial journal
        var journal = JournalEntry(planId: plan.planId, startedAt: Date(), status: .pending, freeSpaceBefore: freeBefore)
        try await journalStore.write(entry: journal)
        
        let sortedSteps = plan.executionOrderedSteps
        
        var hasFailures = false
        
        for step in sortedSteps {
            if hasFailures {
                let hadArchiveFailure = sortedSteps.contains { s in s.kind == .archivePath && journal.stepOutcomes[s.index] != nil && journal.stepOutcomes[s.index] != "ok" }
                if hadArchiveFailure {
                    journal.stepOutcomes[step.index] = "skipped_due_to_prior_failures"
                    continue
                }
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
               !PathExistence.exists(atPath: step.target) {
                journal.stepOutcomes[step.index] = "already_gone"
                continue
            }
            
            do {
                if step.kind == .trashPathPrivileged {
                    // Something in a folder that belongs to root. The
                    // daemon applies its own rules and moves the file to a
                    // holding folder rather than deleting it, so this is
                    // as reversible as the Trash is.
                    guard let privilegedRemover else {
                        journal.stepOutcomes[step.index] = "needs_helper_not_set_up"
                        hasFailures = true
                        continue
                    }
                    if let refusal = await privilegedRemover(step.target) {
                        journal.stepOutcomes[step.index] = "helper_refused: \(refusal)"
                        hasFailures = true
                    } else {
                        journal.stepOutcomes[step.index] = "ok"
                    }
                } else if step.kind == .trashPath || step.kind == .removeLaunchdPlist {
                    guard let fp = step.targetFingerprint else {
                        throw NSError(domain: "BrimSecurity", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing target fingerprint for secure deletion"])
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
                    }

                    switch step.effectiveDisposition {
                    case .trash:
                        let resultingURL = try SafeOps.trashItem(targetPath: step.target, expectedDev: fp.dev, expectedIno: fp.ino)
                        if let url = resultingURL {
                            if journal.stepTrashedURLs == nil { journal.stepTrashedURLs = [:] }
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
                        try PrivacyGrants.resetAll(bundleID: step.target)
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
                        try ToolCleanup.run(id: step.target)
                        journal.stepOutcomes[step.index] = "ok"
                    } catch {
                        journal.stepOutcomes[step.index] =
                            "cleanup_did_not_run: \(error.localizedDescription)"
                    }
                } else if step.kind == .unregisterLaunchServices {
                    // Only the path the app was installed at. A bundle that
                    // went to the Trash keeps its name, so Launch Services
                    // registers it there — but that record is *accurate*:
                    // the app really is in the Trash, and macOS does the same
                    // for any app dragged there by hand. Retracting it is the
                    // Trash's lifecycle, not this step's, and racing Launch
                    // Services to do it here loses: `lsregister -u` exits
                    // non-zero because the record does not exist yet, and the
                    // daemon creates it a moment later.
                    //
                    // Recorded, never fatal — for the same reason as the
                    // privacy reset. The files are already gone; refusing the
                    // whole uninstall over a registration would be the wrong
                    // trade, and the journal says what happened either way.
                    do {
                        try LaunchServicesRegistration.unregister(bundlePath: step.target)
                        journal.stepOutcomes[step.index] = "ok"
                    } catch {
                        journal.stepOutcomes[step.index] =
                            "launch_services_registration_remains: \(error.localizedDescription)"
                    }
                } else if step.kind == .unloadLaunchdJob {
                    try SafeOps.unloadLaunchdJob(path: step.target)
                    journal.stepOutcomes[step.index] = "ok"
                } else if step.kind == .archivePath, let dest = step.archiveDestination {
                    guard let fp = step.targetFingerprint else {
                        throw NSError(domain: "BrimSecurity", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing target fingerprint for secure archive"])
                    }
                    // Validate planned target identity before copying (TOCTOU protection)
                    try SafeOps.verifyTargetFingerprint(targetPath: step.target, expectedDev: fp.dev, expectedIno: fp.ino)
                    
                    let destURL = URL(fileURLWithPath: dest)
                    // Preserve relative directory hierarchy (e.g. "/Applications/App.app" -> "destURL/Applications/App.app")
                    let relPath = step.target.hasPrefix("/") ? String(step.target.dropFirst()) : step.target
                    let itemDestURL = destURL.appendingPathComponent(relPath)
                    
                    try fm.createDirectory(at: itemDestURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                    
                    if fm.fileExists(atPath: itemDestURL.path) {
                        try fm.removeItem(at: itemDestURL)
                    }
                    try fm.copyItem(atPath: step.target, toPath: itemDestURL.path)
                    
                    journal.stepOutcomes[step.index] = "ok"
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
                            try PackageReceipts.forget(packageID: step.target)
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
                }
            } catch let SafeOpsError.failedToRename(err) where err == EPERM {
                journal.stepOutcomes[step.index] = "refusedByOS"
                hasFailures = true
            } catch let SafeOpsError.failedToUnlink(err) where err == EPERM {
                journal.stepOutcomes[step.index] = "refusedByOS"
                hasFailures = true
            } catch {
                let nsErr = error as NSError
                if (nsErr.domain == NSCocoaErrorDomain && nsErr.code == 513) || nsErr.code == EPERM || (nsErr.domain == NSPOSIXErrorDomain && nsErr.code == EPERM) {
                    journal.stepOutcomes[step.index] = "refusedByOS"
                } else {
                    journal.stepOutcomes[step.index] = error.localizedDescription
                }
                hasFailures = true
            }
            
            // Record after each step to handle crashes mid-way. 
            // AUDIT H-6 FIX: Swallow write errors to avoid aborting execution.
            do {
                try await journalStore.write(entry: journal)
            } catch {
                print("Warning: Failed to write journal entry for step \(step.index): \(error)")
            }
        }
        
        var totalFreeAfter: Int64 = 0
        for vol in volumeSet {
            if let free = try? SafeOps.freeSpace(onPath: vol) { totalFreeAfter += free }
        }
        let freeAfter: Int64? = totalFreeAfter > 0 ? totalFreeAfter : (try? SafeOps.freeSpace(onPath: rootPath))
        journal.freeSpaceAfter = freeAfter
        journal.status = hasFailures ? .partial : .completed
        try await journalStore.write(entry: journal)
        
        return journal
    }
}
