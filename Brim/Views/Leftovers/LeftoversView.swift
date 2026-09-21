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
            list.frame(minWidth: 330, idealWidth: 420, maxWidth: 580)
            detail.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.loadIfNeeded(service: service) }
        .sheet(item: $reviewRequest) { intent in
            LeftoverRemovalSheet(intent: intent, service: service) {
                Task { await model.load(service: service) }
            }
        }
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
        if model.isScanning { return "Searching every place an owner could be recorded…" }
        return "\(model.orphanedGroups.count) orphaned · \(model.unclaimedGroups.count) unclaimed, "
             + "grouped by the software that left them"
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning && model.all.isEmpty {
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            VStack(spacing: 6) {
                Text("Could not scan").font(.headline).foregroundColor(.red)
                Text(error).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                section(
                    "Orphaned",
                    "Something recorded an owner and that owner is gone. Pre-selected, "
                    + "because that is evidence.",
                    model.visible(model.orphanedGroups),
                    "Nothing here. No registration, receipt or Launch Services record names "
                    + "software that has since been removed."
                )
                section(
                    "Unclaimed",
                    "No owner found anywhere, and no record of one. A reason to look, not a "
                    + "reason to delete — so none are pre-selected.",
                    model.visible(model.unclaimedGroups),
                    "Nothing unattributable."
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
                    Text("\(title) — \(groups.count)").font(.headline)
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
                    Text("Nothing selected").foregroundColor(.secondary)
                } else {
                    Text("\(model.selectedItems.count) locations · ")
                        .foregroundColor(.secondary)
                    + Text(ByteCountFormatter.string(fromByteCount: model.selectedBytes, countStyle: .file))
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
                Text("Select something to see what it is").font(.headline)
                Text("Brim will show which software left it, how it knows, and what each "
                     + "location actually holds.")
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
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .labelsHidden()
                .disabled(!group.isFullyActionable)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.displayName).fontWeight(.medium)
                    if !group.isFullyActionable {
                        Image(systemName: "lock").font(.caption2).foregroundColor(.orange)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: group.totalBytes, countStyle: .file))
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
                    Text(ByteCountFormatter.string(fromByteCount: group.meaningfulBytes, countStyle: .file)
                         + " of this is data the app would have remembered")
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
                        "What you would lose",
                        ByteCountFormatter.string(fromByteCount: group.meaningfulBytes, countStyle: .file)
                        + " of this is not rebuilt automatically. "
                        + ByteCountFormatter.string(fromByteCount: group.regeneratedBytes, countStyle: .file)
                        + " is cache and temporary files the software recreates by itself.",
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
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
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
