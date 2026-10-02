# Uninstall registration verification

This implementation separates bundle declarations, current registration observations and successful commands. Only a fresh, complete read can establish absence. A missing path is not proof that a registration has disappeared or that a running service stopped.

## Supported removal and recovery

- Privacy resets run before code is moved, under the current user. The host and eligible embedded application, extension and XPC identifiers are reviewed separately. Positive surviving claims and bundled library identifiers are excluded. A successful reset is an action receipt, never a claim that Brim read the private permissions database.
- Launch Services unregisters only reviewed application paths, including embedded applications known before removal. Newly discovered records are shown in the result and require another review. Recovery copies are distinguished from records at the removed path.
- Current-user launch agents use their actual Label and GUI domain. Brim reads the domain and exact service, checks the loaded declaration path, stops it and confirms its absence before moving the declaration. A failed or indeterminate stop keeps the declaration in place; independent file steps can still finish. Undo restores the declaration and bootstraps it in the same domain.
- The authenticated helper independently validates system-job scope and binds the requesting user to the XPC connection. It never accepts a caller-supplied UID. Its interface version is 8.
- Installer records can be forgotten only when their full reviewed payload is bound to the plan and every payload file is freshly absent. The helper independently reads and checks the receipt payload. Live, unreadable, disconnected, malformed or unmeasured payloads keep the receipt.

## Ownership and observation

Exact-identifier application lookup supplements directory discovery. Candidate bundles must contain the expected identifier; aliases of the same filesystem object are deduplicated. Independent copies and positively claimed embedded identifiers remain protected. An incomplete claimant scan suppresses automatic selection without inventing a shared owner.

Registration snapshots retain namespace, stable record identity, raw target, runtime state, timestamp, reader version and read gaps. Ambiguous or cyclic background-item parents stay unresolved. Tool output must satisfy its listing format and count; a successful exit with an invalid listing is not an empty result. Disconnected volumes, denied paths and unresolved targets remain unknown. Legacy journals decode without gaining verification they never recorded.

## Routes withheld from automatic removal

| Surface | Shipped behavior | Reason |
| --- | --- | --- |
| Background Task Management | Observe remaining records; no erasure follow-up | Background controls disable activity but cannot remove the row. No qualified foreign-app per-record removal. Never reset the machine-wide store. |
| PluginKit | Observe all returned versions and duplicates; show the Settings route | The controlled extension registration experiment did not establish a reliable removal lifecycle. No new automatic mutation ships. |
| Legacy Open at Login | Manual Settings route | System Events compatibility is not established on the current system. No automation consent prompt or private store edits. |
| Firewall | Read and attribute exact paths; open Firewall options | Automatic removal remains unqualified by controlled lifecycle evidence. |
| System extensions | Observe listed state and route to the owner or Settings | Brim has no general authority to deactivate another developer's extension. Restart advice requires a documented pending-removal state. |
| VPN and File Provider | Report authority limits and route to the owning app | Owner APIs do not become foreign-app removal APIs under root. Provider containers and cloud support data remain excluded, including manual selection. |

Vendor uninstallers are revealed in Finder, never executed. No follow-up appends commands to an old approved plan.

## Results and history

The result separates files confirmed gone, paths that could not be checked, registrations still listed, surviving claims, recovery copies and completed actions. Technical evidence and observation time sit in Details. Home and Background use “listed”, and read failures produce a partial result. There is no promise that macOS will collect a missing-target background record.

Journal offers Check removal as a read-only action. Each recheck appends an observation without replacing execution receipts or granting approval. It can report a reinstall or newly discovered record but cannot remove either.

## Validation

Validation was performed on macOS 27.0.1 with Xcode 27. The full package suite and signed app build pass strict concurrency and warnings-as-errors. The lint comparison adds no violations. Regression coverage includes ambiguous parent records, invalid successful listings, disconnected targets, persisted-data migration, shared claims, failed job stops, full receipt payload checks and protected provider data.

The owned current-user launchd fixture passed real bootstrap, approved removal, exact-domain readback and undo. Its declaration, runtime job, temporary recovery file and journal were cleaned up, and no fixture jobs or sleep processes remained. The test also triggered macOS background activity notifications. Removing a job does not guarantee collection of its BTM record. This fixture was therefore moved out of the regular test targets into an [isolated-account recipe](fixtures/ScopedRegistrationLifecycleTests.swift.example); do not rerun it in a personal account. Synthetic filesystem tests inject a separate runtime client and never bootstrap their fake declarations.

The built app was inspected on this machine: Background reports listed records and read gaps, and a real historical removal recheck displays a remaining background record and dated evidence in its result sheet. This does not verify privileged system-job mutations or another application's private TCC state.

The rejected PluginKit experiment created one sandbox container during registration. That experiment was removed from the test harness. Finder removed the owned container with the user's approval; the Bin was confirmed empty. No existing user application was uninstalled for validation.

The real Details review exposed excessive centering of the disclosure content. The content now fills the available width with leading alignment, and each capability has a relevant symbol. Action receipts and unknown paths have separate icons. Home's partial-read regression is covered by a focused status test.

Background record targets and their source archive are now labeled separately. A Teams app record and its launch-agent record can share one BTM archive; that is not duplicate discovery. Finder actions reveal individual targets only; they never fall back to the shared archive. The archive is labeled Shared macOS store as evidence. The safety boundary independently vetoes its directory, files and parents, even if explicitly targeted. A set-aside target is retained evidence, not proof of an active process.

## Background removal research, 2 October 2026

The current machine's Settings accessibility tree places Add and Remove under Open at Login. Background App Activity exposes switches and no Remove button. Read-only inspection of the installed LoginItems Settings executable found separate `remove(foregroundItem:)` and `setBackgroundItem(_:allowed:)` operation names. This supports the UI distinction; it is not a traced execution of the minus action and no personal login item was changed.

Apple's documentation describes the Remove control as preventing an Open at Login item from opening automatically, separately from allowing background activity. [Apple's login-item instructions](https://support.apple.com/guide/mac-help/open-items-automatically-when-you-log-in-mh15189/mac)

Apple's DTS service-management example explicitly checks that unregistering unloaded its daemon, while noting that background approval state is retained. This is evidence that even owner-side unregister success does not prove erasure of all BTM state. The documented reset affects login and background data collectively; it is not a selective app operation. [Apple's service-management example](https://developer.apple.com/forums/thread/802443), [deployment guide](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web)

The following projects were read at pinned commits, not installed or exercised. Source shows attempted operations, not successful selective erasure on macOS 27.

| Project and inspected revision | Actual teardown mechanism | Consequence for Brim |
| --- | --- | --- |
| [Mole](https://github.com/tw93/Mole/blob/c430bac637929ebede043df81d3bef319428309c/lib/uninstall/batch.sh) | Stops helper labels in the GUI domain, removes legacy login items and unregisters the app path. It explicitly excludes individual modern BTM removal. | Loaded-service readback is useful; its assumption of pruning at next login is not adopted as a guarantee. |
| [Pearcleaner](https://github.com/alienator88/Pearcleaner/blob/7724df7111bff82ae243301cf701992ef05ecf19/Pearcleaner/Logic/Brew/HomebrewUninstaller.swift) | Homebrew teardown attempts `SMAppService.loginItem(identifier:).unregister()`, catches failure, and separately stops external launch jobs. Its helper repair uses a global reset. | The foreign identifier call remains unqualified. Apple's API is scoped to helpers in the calling app's bundle. Neither catching an error nor a machine-wide reset proves targeted removal. |
| [Homebrew](https://github.com/Homebrew/brew/blob/d6ca35509427ed7b4e37445054fa343ab90755ec/Library/Homebrew/cask/artifact/abstract_uninstall.rb) | Deletes System Events login items by app path or supplied name, stops declared services, and supports app-specific uninstall scripts. | The legacy login-item adapter is worth a controlled compatibility experiment, using exact path and stable identity. It is not a modern BTM adapter. Do not execute downloaded recipes or name-wide deletions. |
| [LuLu](https://github.com/objective-see/LuLu/blob/7d2669ed32e5b195d5863dc9695441d3301ba7b0/LuLu/App/Configure.m) | Its own uninstaller removes its login item through the shared-file-list API, clears owned data through its daemon and requests deactivation of its own system extension. | Owner-side teardown explains why some uninstallers remove more. Brim cannot acquire another app's authority by copying that code. |
| [AppSleuth](https://github.com/YalamberIngnam/appsleuth/blob/e493759a283b666af82fecc94e89cf1f2f70244b/Sources/AppSleuthCore/Scanner.swift) | Explicitly excludes modern BTM, privacy, keychain and file-handler database state from filename-driven removal. | No missing selective BTM erasure route was found here. |
| [Vendor-specific uninstall script](https://github.com/erikstam/uninstaller/blob/6b8f4f47eac027a8670cdbb4b8a352dde28c64a7/fragments/functions.sh) | Uses configured launch declarations and domain-specific stop commands. | App-specific knowledge helps identify helpers but does not justify broad identifier or filename matches. |

Apple's `loginItem(identifier:)` discussion ties its lookup to the calling app's `Contents/Library/LoginItems`. Initializing an object with a foreign identifier is therefore insufficient evidence of a foreign-app removal route. [API documentation](https://developer.apple.com/documentation/servicemanagement/smappservice/loginitem(identifier:))

### Changes made from this investigation

- Removed the Background Settings follow-up from preflight and final results. It could only disable background activity and falsely appeared to finish cleanup. Legacy Open at Login advice now explicitly names that list.
- Removed the preflight promise that macOS clears a background record after removal. Background entries are detected-only until a selective operation is qualified.
- Added bounded reading of embedded LaunchAgents and LaunchDaemons before the host moves. Exact Label, namespace, declaration path and resolved BundleProgram are retained for post-removal runtime checks. A replaced label, unreadable declaration or escaping symlink produces a gap, not a guessed job. Declaration presence is not described as a loaded service. Embedded automatic stopping remains withheld until it has controlled lifecycle evidence.
- Regression tests verify that a loaded job remains in the result after its embedded declaration disappears and that background rows never offer Settings as an erasure step.

### Remaining qualification work

Use the isolated-account fixture recipe with two unrelated sentinel apps and a target containing both an embedded agent and daemon. Record BTM identity, namespace, registration type, actual target, runtime and Settings visibility before and after: owner unregister; exact service bootout; moving the host to Trash; removing its recovery copy; reopening Settings; logout/login; restart; reinstall. Test disabled and missing-target records separately. Never infer record erasure from a stopped process or a vanished Settings row.

Then test the legacy exact-path removal adapter and the foreign login-item attempt independently. Preserve sentinel registrations and their enabled state after every step. A mutation can ship only after repeatable readback, denial behavior, ownership checks and recovery semantics are established. Private BTM archive surgery, global reset and launching arbitrary vendor code remain excluded. No selective BTM erasure has yet met that gate.

Trash remains the default for files. Registration changes such as privacy reset and receipt forgetting cannot be restored by moving a file back and are reviewed as such before approval. A recovery copy is intentionally retained, not a missing-target leftover. Emptying Trash permanently removes its files, but cannot be presented as a guarantee that every macOS database entry vanished.

Final built-app inspection confirmed the result sheet's leading alignment, capability icons, scrolling Details and reachable Done button. A fresh boringNotch history check reported its files absent, the current background-job read gap and the saved privacy-reset receipt, without presenting a Background Settings removal step. The earlier BTM observation and this later read are distinct snapshots; neither predicts when macOS collects another record. The final default suite and app build passed strict concurrency and warnings-as-errors, and the lint comparison added zero violations. Both app signature verification and the pinned helper requirement passed.
