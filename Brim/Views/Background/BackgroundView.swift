import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

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
            Text("\(model.selectedItems.count) job \(model.selectedItems.count == 1 ? "file" : "files") picked")
                .foregroundColor(.secondary)
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
                section(
                    "Left behind",
                    "These point at a program that is not on this Mac any more, and nothing "
                    + "clears them on its own. Each one either fails quietly every time you "
                    + "log in, or keeps running something you thought was gone.",
                    model.stale,
                    "Nothing left over. Every background job here points at software you "
                    + "still have."
                )
                if !model.clearingItself.isEmpty {
                    section(
                        "macOS is catching up",
                        "The software has gone and macOS has not tidied its own list yet. It "
                        + "does that by itself the next time anything asks it for the list, so "
                        + "there is nothing here for you to do.",
                        model.clearingItself,
                        ""
                    )
                }
                section(
                    "Still in use",
                    "Software you have, running in the background. Here so you can see it, "
                    + "not because anything is wrong.",
                    model.live,
                    model.searchText.isEmpty ? "Nothing runs in the background on this Mac."
                                             : "Nothing matches."
                )
            }
            .listStyle(.inset)
        }
    }

    /// What Brim could not read, and why. A list that quietly drops the
    /// half it could not see is worse than one that says so.
    private var coverageNote: some View {
        Section {
            ForEach(model.gaps, id: \.kind) { gap in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "eye.slash").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Part of this list is missing").fontWeight(.medium)
                        Text(gap.limitation ?? "Brim could not read \(gap.kind.displayName).")
                            .font(.callout).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Settings") { FullDiskAccess.openSettings() }
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func section(
        _ title: String, _ caption: String,
        _ groups: [RegistrationGroup], _ emptyNote: String
    ) -> some View {
        Section {
            if groups.isEmpty {
                Text(emptyNote).font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(groups) { group in
                    GroupRow(
                        group: group,
                        canSelect: model.canSelect(group),
                        isSelected: model.isSelected(group),
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

/// One application, and everything macOS has been told to run for it.
private struct GroupRow: View {
    let group: RegistrationGroup
    var canSelect = false
    var isSelected = false
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
                Text(group.displayName).fontWeight(.semibold)
                if group.isSystemOwned {
                    Text("macOS").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(group.composition).font(.caption).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(group.items) { item in RegistrationRow(registration: item) }
            }
            .padding(.leading, 12)
        }
        .padding(.vertical, 4)
    }
}

private struct RegistrationRow: View {
    let registration: Registration

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
            // The record's own path, not just what it points at. Without it
            // Keystone's four identical rows were indistinguishable, and two
            // of them are the same job installed in a different domain.
            if let location = registration.programPath ?? registration.recordPath {
                Text(location)
                    .font(.caption2).foregroundColor(.secondary)
                    .truncationMode(.middle).lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
