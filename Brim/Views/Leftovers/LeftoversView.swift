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
             + "grouped by the software that left them"
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning && model.all.isEmpty {
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            VStack(spacing: 6) {
                Text("The scan stopped early").font(.headline).foregroundColor(.red)
                Text(error).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                section(
                    "Orphaned",
                    "A record on this Mac names the software these belong to, and that "
                    + "software is no longer installed. Ticked for you.",
                    model.visible(model.orphanedGroups),
                    "Nothing here. No record on this Mac points at software that has gone."
                )
                section(
                    "Unclaimed",
                    "No installed application claims these, and no record says one ever "
                    + "did. Worth reading through. Tick the ones you want removed.",
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
                        toggle: { model.toggle(group) },
                        inspect: { model.inspected = group }
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
                Text("Select an entry").font(.headline)
                Text("Brim names the software it belongs to, what each location holds, and "
                     + "what you lose by removing it.")
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
    /// Opening the detail pane. A tap gesture does this for a mouse and
    /// exposes nothing, so without an action of its own the pane that
    /// explains each entry could not be reached at all without one.
    let inspect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Named for the accessibility tree even though the name is not
            // drawn. An empty label exposes nothing to press.
            Toggle("Select \(group.displayName)",
                   isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!group.isFullyActionable)

            // One element rather than nine. The toggle beside it stays
            // addressable on its own, which is the part a reader acts on.
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
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(isInspected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(group.spokenDescription)
            .accessibilityValue(ByteText.short(group.totalBytes))
            .accessibilityHint("Shows what this is and where it lives")
            .accessibilityAction { inspect() }
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

                // What is stopping this, before anything about what it is.
                //
                // The checkbox on this group will not tick and the lock
                // beside its name does not say why. Without this the person
                // clicks, nothing happens, and the only explanation arrives
                // after an authorization that was never going to work.
                if let obstacle = group.sharedObstacle,
                   let why = RemovalCapability.explanation(obstacle) {
                    blockedCallout(why, revealing: group.items.map(\.url))
                }

                // Why Brim thinks this is a leftover at all — the sentence
                // the flat list computed and then discarded.
                callout(
                    group.category == .orphaned ? "checkmark.seal" : "questionmark.circle",
                    group.category == .orphaned ? "Orphaned" : "Unclaimed",
                    group.evidence,
                    group.category == .orphaned ? .accentColor : .secondary
                )

                // The second sentence only exists when there is a second
                // quantity. With nothing regenerable, `ByteText` returns the
                // word "nothing" and the sentence came out as "The other
                // nothing is scratch files the software makes again by
                // itself."
                if group.meaningfulBytes > 0 {
                    callout(
                        "exclamationmark.triangle",
                        "What goes for good",
                        ByteText.inSentence(group.meaningfulBytes)
                        + " of this never comes back once you empty the Trash."
                        + (group.regeneratedBytes > 0
                           ? " The other " + ByteText.inSentence(group.regeneratedBytes)
                             + " is scratch files the software makes again by itself."
                           : ""),
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

    /// What is stopping this, and the one thing that gets somebody past it.
    ///
    /// Finder can remove these; Brim, running as the person, cannot. So the
    /// button hands the whole group over at once and with every file
    /// **selected**, rather than opening the folder and leaving somebody to
    /// find nine names among twenty-seven. `activateFileViewerSelecting`
    /// highlights a broken symbolic link the same as anything else, which
    /// is the case that matters here and the one worth having checked.
    private func blockedCallout(_ why: String, revealing urls: [URL]) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Brim cannot remove this").fontWeight(.medium)
                Text(why).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(urls.count == 1
                     ? "Finder can, and will ask you for a password."
                     : "Finder can, and will ask you once for all \(urls.count).")
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(urls.count == 1 ? "Show in Finder" : "Show all \(urls.count) in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
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
            HStack(spacing: 6) {
                Text(item.url.path)
                    .font(.caption).foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .truncationMode(.middle).lineLimit(1)
                Spacer()
                // Answers "is this really where it says it is" directly,
                // rather than asking someone to trust a path string. Finder
                // shows a broken symlink with its own overlay, so this
                // works exactly the same for the dangling ones.
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
            // Every obstacle, not only the one that had a label written
            // for it. A broken command in a root-owned folder used to show
            // nothing at all here and nothing on its checkbox either.
            //
            // And only when the group did not already say it. Docker leaves
            // seven broken commands in one folder for one reason, and the
            // callout above plus seven copies of the same orange sentence
            // is the wall this was meant to stop being.
            if group.sharedObstacle == nil,
               let why = RemovalCapability.explanation(item.capability) {
                Label(why, systemImage: "lock")
                    .font(.caption2).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
