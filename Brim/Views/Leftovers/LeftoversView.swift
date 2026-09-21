import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// What is left on this Mac that no installed software claims.
///
/// The two categories are never merged, and the difference is stated rather
/// than implied. An orphan names the record that orphaned it. An unclaimed
/// item says plainly that Brim searched and found nothing — which is a
/// reason to look, not a reason to delete, so nothing here is pre-selected.
struct LeftoversView: View {
    @SwiftUI.Environment(\.brimService) private var service

    @StateObject private var model = LeftoversModel()
    @State private var reviewRequest: PlanIntent?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .task { await model.load(service: service) }
        .sheet(item: $reviewRequest) { intent in
            LeftoverRemovalSheet(intent: intent, service: service) {
                Task { await model.load(service: service) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Leftovers").font(.title2).fontWeight(.bold)
                Text(summary).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Button("Rescan") { Task { await model.load(service: service) } }
                .disabled(model.isScanning)
        }
        .padding()
    }

    private var summary: String {
        if model.isScanning { return "Searching every place an owner could be recorded…" }
        let o = model.orphaned.count
        let u = model.unclaimed.count
        return "\(o) orphaned · \(u) unclaimed"
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
                    title: "Orphaned",
                    caption: "Something recorded an owner for these, and that owner is gone. "
                           + "Pre-selected, because that is evidence.",
                    items: model.visible(model.orphaned),
                    emptyNote: "Nothing here. No registration, receipt or Launch Services record "
                             + "names software that has since been removed."
                )
                section(
                    title: "Unclaimed",
                    caption: "Brim searched every mounted volume, every readable account, Launch "
                           + "Services and the installer receipts, and found no owner — and no "
                           + "record of one either. That is not the same as knowing these are "
                           + "disposable, so none are pre-selected.",
                    items: model.visible(model.unclaimed),
                    emptyNote: "Nothing unattributable."
                )
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func section(title: String, caption: String, items: [Leftover], emptyNote: String) -> some View {
        Section {
            if items.isEmpty {
                Text(emptyNote).font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(items) { item in
                    LeftoverRow(
                        item: item,
                        isSelected: model.selection.contains(item.id),
                        // An orphan's evidence names the specific record
                        // that orphaned it, so it belongs on the row. An
                        // unclaimed item's is the same sentence every time
                        // — it is a fact about the search, not about the
                        // item, so it is stated once in the header above.
                        showsEvidence: item.category == .orphaned,
                        toggle: { model.toggle(item) }
                    )
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(title) — \(items.count)")
                        .font(.headline)
                    Spacer()
                    if !items.isEmpty {
                        Button("Select all") { model.selectAll(in: items) }
                            .buttonStyle(.link).font(.caption)
                        Button("None") { model.deselectAll(in: items) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                    Text("\(model.selectedItems.count) selected · ")
                        .foregroundColor(.secondary)
                    + Text(ByteCountFormatter.string(fromByteCount: model.selectedBytes, countStyle: .file))
                        .fontWeight(.bold).monospacedDigit()
                }

                if !model.blockedSelection.isEmpty {
                    Label(
                        "\(model.blockedSelection.count) of these need Full Disk Access — macOS will "
                        + "not let Brim remove a sandbox container without it.",
                        systemImage: "lock"
                    )
                    .font(.caption)
                    .foregroundColor(.orange)
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
}

private struct LeftoverRow: View {
    let item: Leftover
    let isSelected: Bool
    let showsEvidence: Bool
    let toggle: () -> Void

    /// Shown so the list can be triaged, never as an argument for deleting:
    /// nothing having opened a file lately says nothing about whether its
    /// owner is gone.
    private var lastOpened: String? {
        guard let date = item.lastAccessed else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last opened " + formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .labelsHidden()
                .disabled(item.capability != .ok)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent).font(.callout)
                    if item.capability == .needsFullDiskAccess {
                        Label("Needs Full Disk Access", systemImage: "lock")
                            .font(.caption2).foregroundColor(.orange)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .font(.caption).foregroundColor(.secondary).monospacedDigit()
                }
                Text(item.url.path)
                    .font(.caption).foregroundColor(.secondary)
                    .truncationMode(.middle).lineLimit(1)
                if showsEvidence {
                    Text(item.evidence)
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let lastOpened {
                    Text(lastOpened)
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

extension PlanIntent: @retroactive Identifiable {
    public var id: String {
        explicitTargets.map(\.path).joined(separator: "|")
    }
}
