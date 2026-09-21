import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI
import BrimPrivileged

/// What macOS runs on your behalf, and what it is still being told to run
/// for software that is no longer here.
///
/// This is the surface the whole product grew out of. Remove an app without
/// deregistering it and System Settings goes on listing its background item,
/// often as a bare identifier with no name, and no amount of deleting files
/// clears it.
///
/// Two lists, because they call for different things. A job pointing at a
/// program that has gone is a loose end. A job pointing at something real is
/// simply what your Mac is doing, and is here so you can see it.
struct BackgroundView: View {
    @ObservedObject var model: BackgroundModel
    @SwiftUI.Environment(\.brimService) private var service

    @State private var removalRequest: PlanIntent?
    @ObservedObject private var helper: PrivilegedHelperClient

    init(model: BackgroundModel) {
        self.model = model
        self.helper = model.helper
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if model.canRemoveSelection {
                Divider()
                footer
            }
        }
        .task { await model.loadIfNeeded(service: service) }
        .sheet(item: $removalRequest) { intent in
            RemovalSheet(
                intent: intent,
                service: service,
                title: "Remove background jobs",
                subtitle: intent.explicitTargets.count == 1
                    ? "One job file, unloaded and then moved to the Trash"
                    : "\(intent.explicitTargets.count) job files, unloaded and then moved to the Trash"
            ) {
                Task { await model.load(service: service) }
            }
        }
    }

    /// Only appears once something is picked. A permanently visible bar
    /// with a disabled button is an invitation to a screen where most of
    /// the rows are not removable at all.
    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selectedItems.count) job \(model.selectedItems.count == 1 ? "file" : "files") picked")
                    .foregroundColor(.secondary)
                // Said once, here, rather than as a warning on each row.
                // Whether a folder belongs to you or to the system is
                // Brim's problem to solve, not something to make anyone
                // sort their selection by.
                if model.selectionUsesHelper {
                    Text("Some need an administrator. The helper sets those aside so they "
                         + "can be restored.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button("Remove…") {
                removalRequest = model.removalIntent(requesterIdentity: NSUserName())
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background").font(.title2).fontWeight(.bold)
                    Text(summary).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("Include macOS", isOn: $model.showsSystemOwned)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button("Rescan") { Task { await model.load(service: service) } }
                    .disabled(model.isLoading)
            }
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }

    private var summary: String {
        if model.isLoading { return "Reading what macOS has been told to run…" }
        let stale = model.stale.count
        let live = model.live.count
        let apps = live == 1 ? "1 application" : "\(live) applications"
        if stale == 0 { return "\(apps) running something in the background. Nothing left over." }
        let left = stale == 1 ? "1 loose end" : "\(stale) loose ends"
        return "\(left) from software that has gone, and \(apps) you still have"
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.report.registrations.isEmpty {
            ProgressView("Reading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !model.gaps.isEmpty { coverageNote }
                if !model.waitingOnHelper.isEmpty, !helper.state.canRemove { helperSetUpNote }
                section(
                    "Left behind",
                    "The program these launch is no longer installed.",
                    model.stale,
                    ""
                )
                if !model.clearingItself.isEmpty {
                    section(
                        "macOS is catching up",
                        "Removed software macOS has not dropped from its list yet. "
                        + "Nothing to do.",
                        model.clearingItself,
                        ""
                    )
                }
                section(
                    "Still in use",
                    "Installed software running in the background.",
                    model.live,
                    model.searchText.isEmpty ? "" : "Nothing matches."
                )
            }
            .listStyle(.inset)
        }
    }

    /// Offered only when there is something it would actually do. A
    /// standing invitation to install a root daemon, on a Mac with
    /// nothing for it to remove, is not a thing to put in front of
    /// anybody.
    private var helperSetUpNote: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key.horizontal").foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.waitingOnHelper.count) of these need an administrator")
                        .fontWeight(.medium)
                    Text("They are in a system folder. A helper can remove them. It touches "
                         + "only job files in the two system launchd folders, skips Apple's "
                         + "and any job still in use, and sets aside what it removes rather "
                         + "than deleting it.")
                        .font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .waitingForApproval = helper.state {
                        Text("Now allow it in System Settings, under Login Items, and it is done.")
                            .font(.callout).foregroundColor(.orange)
                    }
                    if case .unavailable(let why) = helper.state {
                        Text(why).font(.callout).foregroundColor(.red)
                    }
                    if case .stale(let installed) = helper.state {
                        // Registered, but the root process answering is
                        // the one an older Brim installed, and its rules
                        // about what is safe to remove are that version's
                        // rules. Brim will not use it.
                        Text("The helper already installed is from an older Brim (version "
                             + "\(installed)). It has been replaced, and macOS will start the "
                             + "new one next time. Nothing will be removed until it does.")
                            .font(.callout).foregroundColor(.orange)
                    }
                }
                Spacer()
                if case .waitingForApproval = helper.state {
                    Button("Open Settings") { helper.openSettings() }
                } else {
                    Button("Set up") { helper.install() }
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { helper.refresh() }
        }
    }

    /// What could not be read, and why.
    ///
    /// Only genuine gaps. A surface deliberately left alone is not a
    /// fault and gets no panel: a box explaining something that is not
    /// there is three lines about nothing, and it appeared with a button
    /// offering to open Full Disk Access on a Mac where Full Disk Access
    /// was already granted.
    private var coverageNote: some View {
        Section {
            ForEach(model.faults, id: \.kind) { gap in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "eye.slash").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Part of this list is missing").fontWeight(.medium)
                        Text(gap.limitation ?? "\(gap.kind.displayName)s could not be read.")
                            .font(.callout).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    // Only where a permission is actually the thing in the
                    // way. Offering Settings for a tool that did not answer
                    // sends somebody to flip a switch that changes nothing.
                    if gap.isFixableByTheUser {
                        Button("Open Settings") { FullDiskAccess.openSettings() }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

        }
    }

    /// An empty section is not drawn. A heading, a caption and a row
    /// saying "None" is three lines about nothing, and the emptyNote is
    /// kept only for the one case where a search matched nothing and the
    /// person needs telling why the list went blank.
    @ViewBuilder
    private func section(
        _ title: String, _ caption: String,
        _ groups: [RegistrationGroup], _ emptyNote: String
    ) -> some View {
        if !groups.isEmpty || !emptyNote.isEmpty {
            Section {
                if groups.isEmpty {
                    Text(emptyNote).font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(groups) { group in
                        GroupRow(
                            group: group,
                            canSelect: model.canSelect(group),
                            isSelected: model.isSelected(group),
                            helperIsReady: helper.state.canRemove,
                            toggle: { model.toggle(group) }
                        )
                    }
                }
            } header: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(title) (\(groups.count))").font(.headline)
                    Spacer()
                    if title == "Still in use", model.hiddenSystemCount > 0 {
                        Text("\(model.hiddenSystemCount) from macOS hidden")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Text(caption).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// One application, and everything macOS has been told to run for it.
private struct GroupRow: View {
    let group: RegistrationGroup
    var canSelect = false
    var isSelected = false
    /// Whether the privileged daemon is set up. A row that needs it stops
    /// saying so once it does.
    var helperIsReady = false
    var toggle: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if canSelect {
                    // A real label, hidden visually rather than absent. An
                    // empty one leaves nothing for the accessibility tree
                    // to expose, and the control reads as scenery: the same
                    // way the sidebar rows looked operable and were not.
                    Toggle("Select \(group.displayName)",
                           isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }

                // The rest of the header is one element, not four. Left as
                // separate views it reached a reader as a name, then a
                // badge, then a team identifier, then a count, with nothing
                // saying they were about the same application.
                HStack(spacing: 6) {
                    Text(group.displayName).fontWeight(.semibold)
                    if group.isSystemOwned {
                        Text("macOS").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    if let team = group.signedBy {
                        Text(team).font(.caption2).foregroundColor(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    Text(group.composition).font(.caption).foregroundColor(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(group.spokenDescription)
                .accessibilityAddTraits(.isHeader)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(group.items) { item in
                    RegistrationRow(registration: item, helperIsReady: helperIsReady)
                }
            }
            .padding(.leading, 12)
        }
        .padding(.vertical, 4)
    }
}

private struct RegistrationRow: View {
    let registration: Registration
    var helperIsReady = false

    /// Something Brim cannot reach itself but the daemon can, right now.
    private var reachableWithHelper: Bool {
        helperIsReady && BackgroundModel.needsTheHelper(registration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(registration.label).font(.callout)
                Text(registration.kind.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                Spacer()
                if registration.isActionableStale {
                    if registration.isClearedByMacOS {
                        Label("macOS will drop this", systemImage: "clock")
                            .font(.caption2).foregroundColor(.secondary)
                    } else {
                        Label("Points at nothing", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundColor(.orange)
                    }
                }
            }
            Text(registration.evidence)
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Who signed the thing macOS is being told to run. Not shown
            // when it is unremarkable: a line on every row saying the
            // signature is fine is a line nobody reads, and then the one
            // that says otherwise is not read either.
            if let signing = registration.signing, signing.isTrouble {
                Label(signing.sentence, systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Said before it is attempted, not after it fails. Once the
            // helper is set up this stops being true of the jobs it can
            // reach, so the row stops saying it.
            if registration.isActionableStale,
               !reachableWithHelper,
               let blocked = RemovalCapability.explanation(registration.capability) {
                HStack(spacing: 6) {
                    Label(blocked, systemImage: "lock")
                        .font(.caption).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if let path = registration.recordPath {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: path)
                            ])
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
            // The record's own path, not just what it points at. Without it
            // Keystone's four identical rows were indistinguishable, and two
            // of them are the same job installed in a different domain.
            if let location = registration.spokenLocation {
                Text(location)
                    .font(.caption2).foregroundColor(.secondary)
                    .truncationMode(.middle).lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        // One element per entry, composed rather than inferred. Left to
        // SwiftUI this row arrived as seven unrelated fragments, and the
        // selectable path arrived twice, because textSelection adds a
        // child of its own.
        .accessibilityElement(children: .ignore)
        // Without a trait the combined element has no role and exposes as
        // AXUnknown, which is how the sidebar rows once looked operable to
        // a reader while being nothing at all. An entry here is text, so
        // it says it is text.
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(registration.spokenDescription)
        .accessibilityValue(registration.spokenLocation ?? "")
    }
}
