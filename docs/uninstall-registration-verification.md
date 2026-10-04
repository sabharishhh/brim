# Uninstall registration verification

This implementation separates bundle declarations, current registration observations and successful commands. Only a fresh, complete read can establish absence. A missing path is not proof that a registration has disappeared or that a running service stopped.

## Release scope, 4 October 2026

The release goal is reliable supported deep uninstall. Automatic removal of
every file, helper, permission and registration for every app is not achieved
and is not a release completion requirement.

| Area | Achieved | Limit |
| --- | --- | --- |
| Ownership | Traces associated files/components and protects surviving installations and shared claims | An incomplete search stays incomplete; resemblance alone does not authorize removal. |
| Files and helpers | Removes approved items through qualified user/admin routes; discovers helper apps in selected support/cache folders | OS-protected, shared and unsupported locations can remain. No installation type has a universal all-traces guarantee. |
| Registrations | Exact Launch Services cleanup/readback, supported launch-job stop/readback and qualified receipt cleanup | Many login/background, plug-in, firewall, extension, VPN, profile and provider records remain observational or manual. |
| Privacy | Scoped reset commands for eligible identifiers before code moves | Command success is not an independent read of every private permission record. |
| Remnants and recovery | Grouped selection/removal, Trash and eligible Undo, explicit protected-copy deletion | Permanent actions and protected recovery copies have no restore action in Brim. |
| Administrator access | Shared authentication through execution/verification of a selected batch; temporary process exits afterward or when Brim closes | Protected work still needs authentication. Reading protected copies is a separate explicit action. |
| Verification | Distinguishes absent files, remaining records, unreadable paths, surviving copies and action receipts; Journal rechecks unfinished removals | A stopped job or deleted file does not prove its registration disappeared. |

### What has not been verified universally

There is no complete lifecycle qualification across every app package,
installation method and macOS version. Actual machine checks and fixture
coverage are recorded separately below. The latest folder-registration and
shutdown fixes have fixture coverage; no additional destructive live batch
was run. Emptying Trash, opening Settings, logging in again or restarting is
not a universal cleanup guarantee. Restart guidance must name a supported
pending state, not promise that every remaining record will vanish.

### Why further universal removal is deferred

A selective removal route can be valuable when a remaining item still starts
software or controls an active permission. A stale display entry alone does
not establish a running helper. Forcing that entry out of a shared database
can change unrelated apps' state. Owner-scoped APIs, protected data and
version-specific formats make universal erasure a much larger compatibility
and recovery commitment than its immediate benefit warrants for this release.

Further universal erasure is therefore deferred, not another completion
blocker. Brim retains and explains unsupported records. Broad resets,
private database surgery, arbitrary vendor scripts and blanket restart advice
remain outside the scope.

Future contributors should first fix reproducible defects in attribution,
supported execution, verification and recovery. Consider a new selective
adapter when it offers concrete user benefit, legitimate authority, exact
ownership, repeatable independent readback and known failure/recovery behavior.
Qualify it in an isolated account or VM while preserving unrelated sentinel
apps. This keeps the foundation extensible without an unlimited removal loop.
Deferral does not justify skipping associated-file discovery, weakening
classification or hiding failed supported actions.

## Supported removal and recovery

- Privacy resets run before code is moved, under the current user. The host and eligible embedded application, extension and XPC identifiers are reviewed separately. Positive surviving claims and bundled library identifiers are excluded. A successful reset is an action receipt, never a claim that Brim read the private permissions database.
- Launch Services unregisters only reviewed application paths, including embedded applications known before removal. Newly discovered records are shown in the result and require another review. Recovery copies are distinguished from records at the removed path.
- Selected support and cache folders can contain separate helper applications. Bounded discovery now captures those applications before removal and checks Launch Services at their exact reviewed paths afterward, including grouped remnants and protected recovery copies. An incomplete discovery remains a reported gap. Undo validates the restored folder and application identity before registering the exact application path again.
- Current-user launch agents use their actual Label and GUI domain. Brim reads the domain and exact service, checks the loaded declaration path, stops it and confirms its absence before moving the declaration. A failed or indeterminate stop keeps the declaration in place; independent file steps can still finish. Undo restores the declaration and bootstraps it in the same domain.
- The temporary authenticated helper independently validates system-job scope and binds the requesting user to the connection. It never accepts a caller-supplied UID. Its interface version is 12 and disconnect shutdown is bounded to three seconds. One protected batch holds administrator access through execution and fresh verification, then closes the helper. No persistent background service is registered.
- Installer records can be forgotten only when their full reviewed payload is bound to the plan and every payload file is freshly absent. The helper independently reads and checks the receipt payload. Live, unreadable, disconnected, malformed or unmeasured payloads keep the receipt.

## Ownership and observation

Exact-identifier application lookup supplements directory discovery. Candidate bundles must contain the expected identifier; aliases of the same filesystem object are deduplicated. Independent copies and positively claimed embedded identifiers remain protected. An incomplete claimant scan suppresses automatic selection without inventing a shared owner.

Registration snapshots retain namespace, stable record identity, raw target, runtime state, timestamp, reader version and read gaps. Ambiguous or cyclic background-item parents stay unresolved. Tool output must satisfy its listing format and count; a successful exit with an invalid listing is not an empty result. Disconnected volumes, denied paths and unresolved targets remain unknown. Legacy journals decode without gaining verification they never recorded.

## Routes withheld from automatic removal

| Surface | Shipped behavior | Reason |
| --- | --- | --- |
| Background Task Management | Observe remaining records; conditionally route to Open at Login and check again | The foreground Remove control and background switches are different operations. No qualified automatic foreign-app per-record removal. Never reset the machine-wide store. |
| PluginKit | Observe all returned versions and duplicates; show the Settings route | The controlled extension registration experiment did not establish a reliable removal lifecycle. No new automatic mutation ships. |
| Legacy Open at Login | Manual Settings route | System Events compatibility is not established on the current system. No automation consent prompt or private store edits. |
| Firewall | Read and attribute exact paths; open Firewall options | Automatic removal remains unqualified by controlled lifecycle evidence. |
| System extensions | Observe listed state and route to the owner or Settings | Brim has no general authority to deactivate another developer's extension. Restart advice requires a documented pending-removal state. |
| VPN and File Provider | Report authority limits and route to the owning app | Owner APIs do not become foreign-app removal APIs under root. Provider containers and cloud support data remain excluded, including manual selection. |
| Management profiles | Report exact bundle references from recognized privacy payloads and open Device Management | Profiles may control several apps or belong to an administrator. A current-user listing cannot prove that device policy is absent. |

Vendor uninstallers are revealed in Finder, never executed. No follow-up appends commands to an old approved plan.

## Review corrections

Failed application lookups retain uncertainty, including in leftover classification. Independently installed copies protect exact helper and group claims even when another part of the search is incomplete.

Registration commands have deadlines and output limits. Launch-job declarations are bounded regular-file reads, with declaration and executable provenance checked before mutation. A stop command whose later check fails retains a separate receipt and keeps its declaration. Recovery can retry without starting jobs that were already absent, overwriting execution history or accepting a replacement at the restored path. The helper version changes when these checks change.

Checks with missing or damaged execution journals return an explicit unknown result. Fresh complete observations, completed commands and failed commands remain separate. Recovery completion is recorded independently of the original removal and its checks.

Background displays only records with an application association. Protected system job folders are outside this application scan; malformed or unreadable application declarations still report a gap. The full registration report remains available for inspection and uninstall planning.

## Results and history

The result separates files confirmed gone, paths that could not be checked, registrations still listed, surviving claims, recovery copies and completed actions. Technical evidence and observation time sit in Details. Home and Background use “listed”, and read failures produce a partial result. There is no promise that macOS will collect a missing-target background record.

Journal offers Check removal as a read-only action. Each recheck appends an observation without replacing execution receipts or granting approval. It can report a reinstall or newly discovered record but cannot remove either.

## Validation

Validation was performed on macOS 27.0.1 with Xcode 27. The full package suite and signed app build pass strict concurrency. The final build reported no compiler warnings and the lint comparison adds no violations. Regression coverage includes ambiguous parent records, invalid successful listings, disconnected targets, persisted-data migration, shared claims, failed job stops, full receipt payload checks and protected provider data.

The owned current-user launchd fixture passed real bootstrap, approved removal, exact-domain readback and undo. Its declaration, runtime job, temporary recovery file and journal were cleaned up, and no fixture jobs or sleep processes remained. The test also triggered macOS background activity notifications. Removing a job does not guarantee collection of its BTM record. This fixture was therefore moved out of the regular test targets into an [isolated-account recipe](fixtures/ScopedRegistrationLifecycleTests.swift.example); do not rerun it in a personal account. Synthetic filesystem tests inject a separate runtime client and never bootstrap their fake declarations.

The built app was inspected on this machine: Background reports listed records and read gaps, and a real historical removal recheck displays a remaining background record and dated evidence in its result sheet. This does not verify privileged system-job mutations or another application's private TCC state.

The rejected PluginKit experiment created one sandbox container during registration. That experiment was removed from the test harness. Finder removed the owned container with the user's approval; the Bin was confirmed empty. A later approved desktop-app uninstall exercised file removal, restoration and registration rechecks. That live test is described below.

The real Details review exposed excessive centering of the disclosure content. The content now fills the available width with leading alignment, and each capability has a relevant symbol. Action receipts and unknown paths have separate icons. Home's partial-read regression is covered by a focused status test.

Background record targets and their source archive are now labeled separately. An app record and its launch-agent record can share one BTM archive; that is not duplicate discovery. Finder actions reveal individual targets only; they never fall back to the shared archive. The archive is labeled Shared macOS store as evidence. The safety boundary independently vetoes its directory, files and parents, even if explicitly targeted. A set-aside target is retained evidence, not proof of an active process.

## Background removal research, 2 October 2026

The initial Settings inspection placed Add and Remove under Open at Login. Background App Activity exposed switches and no Remove button. Read-only inspection of the installed LoginItems Settings executable found separate `remove(foregroundItem:)` and `setBackgroundItem(_:allowed:)` operation names. That initial inspection changed no login items. The later approved manual removal below confirmed that the foreground Remove action cleared the observed helper's login and background records.

Apple's documentation describes the Remove control as preventing an Open at Login item from opening automatically, separately from allowing background activity. [Apple's login-item instructions](https://support.apple.com/guide/mac-help/open-items-automatically-when-you-log-in-mh15189/mac)

Apple's DTS service-management example explicitly checks that unregistering unloaded its daemon, while noting that background approval state is retained. This is evidence that even owner-side unregister success does not prove erasure of all BTM state. The documented reset affects login and background data collectively; it is not a selective app operation. [Apple's service-management example](https://developer.apple.com/forums/thread/802443), [deployment guide](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web)

Apple's `loginItem(identifier:)` discussion ties its lookup to the calling app's `Contents/Library/LoginItems`. Initializing an object with a foreign identifier is therefore insufficient evidence of a foreign-app removal route. [API documentation](https://developer.apple.com/documentation/servicemanagement/smappservice/loginitem(identifier:))

### Changes made from this investigation

- Removed the suggestion that a Background App Activity switch finishes registration cleanup. Remaining user login/background records now receive conditional Open at Login instructions and a direct Settings link. This is a manual follow-up, not an automatic removal step.
- Removed the preflight promise that macOS clears a background record after removal. Background entries are detected-only until a selective operation is qualified.
- Added bounded reading of embedded LaunchAgents and LaunchDaemons before the host moves. Exact Label, namespace, declaration path and resolved BundleProgram are retained for post-removal runtime checks. A replaced label, unreadable declaration or escaping symlink produces a gap, not a guessed job. Declaration presence is not described as a loaded service. Embedded automatic stopping remains withheld until it has controlled lifecycle evidence.
- Regression tests verify that a loaded job remains in the result after its embedded declaration disappears, and that conditional login instructions are offered only for remaining records. Preserved installations, recovery copies and unavailable empty reads do not produce that instruction.

### Deferred qualification research

This is an optional research path if a selective route is revisited, not
unfinished implementation required for this release.

Use the isolated-account fixture recipe with two unrelated sentinel apps and a target containing both an embedded agent and daemon. Record BTM identity, namespace, registration type, actual target, runtime and Settings visibility before and after: owner unregister; exact service bootout; moving the host to Trash; removing its recovery copy; reopening Settings; logout/login; restart; reinstall. Test disabled and missing-target records separately. Never infer record erasure from a stopped process or a vanished Settings row.

Evaluate legacy exact-path removal only if there is a legitimate selective route. An owner-scoped API does not qualify merely because it accepts another app's identifier. Preserve sentinel registrations and their enabled state after every step. A mutation can ship only after repeatable readback, denial behavior, ownership checks and recovery semantics are established. Private BTM archive surgery, global reset and launching arbitrary vendor code remain excluded. No selective automatic BTM erasure has yet met that gate.

Trash remains the default for files. Registration changes such as privacy reset and receipt forgetting cannot be restored by moving a file back and are reviewed as such before approval. A recovery copy is intentionally retained, not a missing-target leftover. Emptying Trash permanently removes its files, but cannot be presented as a guarantee that every macOS database entry vanished.

Earlier built-app inspection confirmed the result sheet's leading alignment, capability icons, scrolling Details and reachable Done button. A historical removal check reported files absent, a background-job read gap and the saved privacy-reset receipt. The application-only scan subsequently excluded protected OS job folders, while malformed or unreadable application declarations still report a gap. These reads are distinct snapshots; neither predicts when macOS collects another record. The default suite and app build passed strict concurrency at that checkpoint, and the lint comparison added zero violations. Both app signature verification and the pinned helper requirement passed.

Following the user's final visual review, Details icons are vertically centered against each complete text block rather than aligned to the title's top edge.

## Missing-target login item follow-up

Emptying Trash did not clear one removed helper's Open at Login entry or its background record. A read-only snapshot of the public, deprecated session shared-file-list API did not contain that helper, so that API is not a removal route for this observed record. Selecting the helper in Open at Login and clicking Remove cleared both Settings entries. A fresh Brim scan also confirmed its BTM record absent. No restart was performed and unrelated entries remained listed.

Brim now offers conditional Open at Login instructions and a direct Settings link for remaining user login/background records. BTM's type alone cannot establish that Settings offers a foreground Remove control. The result therefore asks the user to remove it only if it appears in Open at Login, distinguishes background switches from removal, and requires another check. Preserved installations, recovery copies, system records and unavailable empty reads do not produce that follow-up. This is a manual route, not automatic universal registration erasure.

At the previous checkpoint, the default package suite, signed strict-concurrency app build and pinned app identity check passed. Lint added no violations. The built app's actual uninstall recheck confirmed all 18 file locations gone and login/background registrations clear. Management-profile coverage remained unavailable and was shown in the result; privacy, VPN and cloud records retain their documented observation limits.

The final review exercised the rendered Open Login Items link from an existing historical removal's read-only Journal check. The conditional instruction and link were visible, and clicking the link opened System Settings directly to Login Items. The removed test helper remained absent from both Settings lists. The final review also corrected an obsolete helper-activation instruction and the overview's blanket restore promise.

The final full default package suite and signed strict-concurrency build passed. The build reported no compiler warnings, lint added no violations, and both pinned signing identities passed verification. The built app opened, reported Trash empty and showed ten background groups without the removed test helper. No persistent administrator service or temporary helper process was loaded. The new folder-registration and shutdown regressions use fixtures; no additional permanent recovery deletion or registration lifecycle experiment was run on this account.
