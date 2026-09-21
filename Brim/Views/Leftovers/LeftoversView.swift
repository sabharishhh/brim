import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// What is left on this Mac that no installed software claims.
///
/// Organised by software rather than by path. The first version listed one
/// row per directory, which meant the same tool appeared several times with
/// nothing connecting the rows — `Application Support/Codex` and
/// `Caches/Codex` sat apart as if unrelated — and each row offered only a
/// name, a path and a size. None of that helps anyone decide, and the
/// decision is about an application, not a folder.
///
/// So: one entry per piece of software, and a detail pane answering "what is
/// this, and what do I lose" out of facts Brim already had and was throwing
/// away — the owner it inferred, the evidence that decided the category, and
/// what each location is actually for.
struct LeftoversView: View {
    @ObservedObject var model: LeftoversModel
    @SwiftUI.Environment(\.brimService) private var service

    @State private var reviewRequest: PlanIntent?

    var body: some View {
        HSplitView {
            list.frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
            detail.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.loadIfNeeded(service: service) }
        .focusedSceneValue(\.removeSelectedAction, removeSelectedIfPossible)
        .sheet(item: $reviewRequest) { intent in
            RemovalSheet(
                intent: intent,
                service: service,
                title: "Remove leftovers",
                subtitle: "\(intent.explicitTargets.count) items nothing on this Mac claims"
            ) {
                Task { await model.load(service: service) }
            }
        }
    }

    /// Backs the Action menu's Remove Selected, so the keyboard reaches the
    /// same place the button does. Nil when there is nothing to remove,
    /// which is what greys the menu item out.
    private var removeSelectedIfPossible: (() -> Void)? {
        guard model.canRemoveSelection else { return nil }
        return { reviewRequest = model.removalIntent(requesterIdentity: NSUserName()) }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leftovers").font(.title2).fontWeight(.bold)
                    Text(summary).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Rescan") { Task { await model.load(service: service) } }
                    .disabled(model.isScanning)
            }
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }

    private var summary: String {
        if model.isScanning { return "Checking everywhere an owner could be written down…" }
        return "\(model.orphanedGroups.count) orphaned · \(model.unclaimedGroups.count) unclaimed, "
             + "gathered up by the software that left them"
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning && model.all.isEmpty {
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            VStack(spacing: 6) {
                Text("The scan did not finish").font(.headline).foregroundColor(.red)
                Text(error).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                section(
                    "Orphaned",
                    "Something on this Mac named an owner for these, and that owner has gone. "
                    + "Brim has ticked them, because it can show you why.",
                    model.visible(model.orphanedGroups),
                    "Nothing here. No registration, receipt or Launch Services entry points at "
                    + "software that has since gone."
                )
                section(
                    "Unclaimed",
                    "Nothing claims these and nothing remembers claiming them. Worth a look, "
                    + "but not proof of anything, so Brim leaves them unticked.",
                    model.visible(model.unclaimedGroups),
                    "Everything here has an owner."
                )
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func section(
        _ title: String, _ caption: String,
        _ groups: [LeftoverGroup], _ emptyNote: String
    ) -> some View {
        Section {
            if groups.isEmpty {
                Text(emptyNote).font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(groups) { group in
                    GroupRow(
                        group: group,
                        isSelected: model.isSelected(group),
                        isInspected: model.inspected?.id == group.id,
                        toggle: { model.toggle(group) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.inspected = group }
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(title) (\(groups.count))").font(.headline)
                    Spacer()
                    if !groups.isEmpty {
                        Button("Select all") { model.selectAll(groups: groups) }
                            .buttonStyle(.link).font(.caption)
                        Button("None") { model.deselectAll(groups: groups) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                Text(caption).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if model.selectedItems.isEmpty {
                    Text("Nothing picked yet").foregroundColor(.secondary)
                } else {
                    Text("\(model.selectedItems.count) locations · ")
                        .foregroundColor(.secondary)
                    + Text(ByteText.short(model.selectedBytes))
                        .fontWeight(.bold).monospacedDigit()
                }
                if !model.blockedSelection.isEmpty {
                    Label("\(model.blockedSelection.count) need Full Disk Access", systemImage: "lock")
                        .font(.caption).foregroundColor(.orange)
                }
            }
            Spacer()
            Button("Review & Remove…") {
                reviewRequest = model.removalIntent(requesterIdentity: NSUserName())
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canRemoveSelection)
        }
        .padding()
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let group = model.inspected {
            LeftoverDetail(group: group)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "questionmark.folder")
                    .font(.largeTitle).foregroundColor(.secondary)
                Text("Pick something to find out what it is").font(.headline)
                Text("Brim will name the software it came from, say how it worked that out, and "
                     + "tell you what sits in each place.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Row

private struct GroupRow: View {
    let group: LeftoverGroup
    let isSelected: Bool
    let isInspected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Named for the accessibility tree even though the name is not
            // drawn. An empty label exposes nothing to press.
            Toggle("Select \(group.displayName)",
                   isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!group.isFullyActionable)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.displayName).fontWeight(.medium)
                    if !group.isFullyActionable {
                        Image(systemName: "lock").font(.caption2).foregroundColor(.orange)
                    }
                    Spacer()
                    Text(ByteText.short(group.totalBytes))
                        .font(.caption).foregroundColor(.secondary).monospacedDigit()
                }

                // What it is made of, rather than a path to parse.
                HStack(spacing: 4) {
                    Text("\(group.items.count) \(group.items.count == 1 ? "location" : "locations")")
                    ForEach(group.domains.prefix(4), id: \.self) { domain in
                        Text(domain.title)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(
                                (domain.isRegenerated ? Color.secondary : Color.orange).opacity(0.15),
                                in: Capsule()
                            )
                    }
                }
                .font(.caption2).foregroundColor(.secondary)

                if group.meaningfulBytes > 0 {
                    Text(ByteText.short(group.meaningfulBytes)
                         + " of this is what the app would have remembered about you")
                        .font(.caption2).foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 3)
        .background(isInspected ? Color.accentColor.opacity(0.10) : .clear)
    }
}

// MARK: - Detail pane

private struct LeftoverDetail: View {
    let group: LeftoverGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.displayName).font(.title2).fontWeight(.bold)
                    if let identifier = group.identifier {
                        Text(identifier).font(.caption).foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // Why Brim thinks this is a leftover at all — the sentence
                // the flat list computed and then discarded.
                callout(
                    group.category == .orphaned ? "checkmark.seal" : "questionmark.circle",
                    group.category == .orphaned ? "Orphaned" : "Unclaimed",
                    group.evidence,
                    group.category == .orphaned ? .accentColor : .secondary
                )

                if group.meaningfulBytes > 0 {
                    callout(
                        "exclamationmark.triangle",
                        "What goes for good",
                        ByteText.inSentence(group.meaningfulBytes)
                        + " of this never comes back once you empty the Trash. The other "
                        + ByteText.inSentence(group.regeneratedBytes)
                        + " is scratch files the software makes again by itself.",
                        .orange
                    )
                }

                if let accessed = group.lastAccessed {
                    let formatter = RelativeDateTimeFormatter()
                    Text("Last opened " + formatter.localizedString(for: accessed, relativeTo: Date()))
                        .font(.caption).foregroundColor(.secondary)
                }

                Divider()

                Text("Where it is").font(.headline)
                ForEach(group.items) { item in
                    location(item)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func callout(_ symbol: String, _ title: String, _ body: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(body).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private func location(_ item: Leftover) -> some View {
        let domain = LeftoverDomain.of(item.url)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(domain.title).fontWeight(.medium)
                Text(domain.consequence)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(
                        (domain.isRegenerated ? Color.secondary : Color.orange).opacity(0.15),
                        in: Capsule()
                    )
                Spacer()
                Text(ByteText.short(item.size))
                    .font(.caption).foregroundColor(.secondary).monospacedDigit()
            }
            Text(domain.whatItHolds)
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.url.path)
                .font(.caption).foregroundColor(.secondary)
                .textSelection(.enabled)
                .truncationMode(.middle).lineLimit(1)
            if item.capability == .needsFullDiskAccess {
                Label("Brim cannot remove this without Full Disk Access", systemImage: "lock")
                    .font(.caption2).foregroundColor(.orange)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension PlanIntent: @retroactive Identifiable {
    public var id: String {
        explicitTargets.map(\.path).joined(separator: "|")
    }
}
