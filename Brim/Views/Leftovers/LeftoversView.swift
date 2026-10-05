import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// Remnants: apps that have left this Mac and what each one left behind.
///
/// Called "Removed" until 29 Sep, which named the apps rather than what
/// the page is about, and read as a list of things already dealt with.
///
/// One row per app, named and shown as the app was, with when Brim saw it
/// go. The one action finishes the removal: it opens the same review an
/// uninstall uses, where what is certain is ticked and what is not is
/// shown and left. Traces nobody can be named for sit in one collapsible
/// section and are never counted.
struct LeftoversView: View {
    @ObservedObject var model: LeftoversModel
    /// The Trash, shared with Home and the Journal because the Trash is one
    /// thing and two watchers would poll it twice.
    @ObservedObject var recovery: RecoveryStatusModel
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(ShellState.self) private var shell
    @SwiftUI.Environment(AppSession.self) private var session
    @State private var review: PlanIntent?
    /// Locations removed while the review was open, for the toast.
    @State private var removedInReview = 0
    /// Cards showing the places their app left.
    @State private var opened: Set<String> = []
    @State private var showsUnknown = true
    @State private var recoveryReadError: String?
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            content
            if !model.all.isEmpty {
                LeftoverBatchActions(
                    selectedCount: model.selectedItems.count,
                    canRemoveSelection: model.canRemoveSelection && !model.isScanning,
                    canRemoveAll: !model.removableOrphans.isEmpty && !model.isScanning,
                    clear: { model.deselectAll(in: model.all) },
                    removeSelected: { openSelection() },
                    removeAll: {
                        model.selectAllRemovableOrphans()
                        openSelection()
                    }
                )
            }
        }
        .frame(minWidth: Metrics.listMinWidth, maxWidth: .infinity)
        .pageTitle("Remnants", subtitle: model.checkedAt == nil ? nil : summary)
        .alert("Recovery copies could not be read", isPresented: Binding(
            get: { recoveryReadError != nil },
            set: {
                if !$0 {
                    recoveryReadError = nil
                }
            }
        )) {
            Button("OK") { recoveryReadError = nil }
        } message: {
            Text(recoveryReadError ?? "")
        }
        .sheet(item: $review) { intent in
            RemovalPanel(
                intent: intent, service: service,
                onRemoved: { paths in
                    removedInReview += paths.count
                    model.forget(paths: paths)
                },
                onClose: { proven in
                    review = nil
                    if let proven {
                        offerPutBack(proven.planId)
                    }
                },
                onUnverified: { Task { await model.load(service: service) } },
                onPhase: { _ in }
            )
            .frame(width: 560, height: 600)
        }
        .task { await model.loadIfNeeded(service: service) }
        .task { await recovery.start(service: service) }
        .task(id: model.checkedAt) {
            guard model.checkedAt != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            session.visits.acknowledge("leftovers", current: Set(model.all.map(\.id)))
        }
        // Restoring from the Trash puts files back where they were, so
        // their rows belong back in the list.
        .onChange(of: recovery.items) { _, _ in model.reconcileWithDisk() }
    }
}

private extension LeftoversView {
    private var summary: String {
        let groups = model.orphanedGroups
        guard !groups.isEmpty else {
            return model.hasUnreadRecoveryCopies ? "Recovery copies not checked" : "Nothing left behind"
        }
        let apps = groups.count == 1 ? "1 app" : "\(groups.count) apps"
        if groups.flatMap(\.items).contains(where: { $0.sizeIsKnown == false }) {
            return "\(apps) left traces, size not fully measured"
        }
        let bytes = groups.reduce(0) { $0 + $1.totalBytes }
        // "1 app left Empty" was what a removed app with only empty
        // folders behind it read as.
        return bytes == 0 ? "\(apps) left traces" : "\(apps) left \(ByteText.short(bytes))"
    }

    // MARK: - List

    private var unknowns: [LeftoverGroup] {
        model.unclaimedGroupsForReview.sorted { $0.totalBytes > $1.totalBytes }
    }

    private var apps: [LeftoverGroup] {
        model.orphanedGroups.sorted { $0.totalBytes > $1.totalBytes }
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning, model.all.isEmpty {
            SkeletonRows(showsTick: false)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if let error = model.errorMessage {
            EmptyState.couldNotRead(error) { Task { await model.load(service: service) } }
        } else if apps.isEmpty, unknowns.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "Nothing left behind",
                       message: "No removed app has left anything on this Mac.")
        } else {
            list.refreshing(model.isScanning)
        }
    }

    /// Two kinds of thing, drawn as two kinds of thing. An app that left
    /// something is a card: its icon, when it went, and the places it left
    /// folded inside. What nobody can be named for is a plain, quieter list
    /// beneath, open by default and never counted. They used to be the same
    /// row in two sections, so the page read as one list of equals.
    private var list: some View {
        List {
            Group {
                sectionTitle("Removed apps", count: apps.count, bytes: apps.reduce(0) { $0 + $1.totalBytes },
                             sizeIsKnown: !apps.flatMap(\.items).contains { $0.sizeIsKnown == false })
                if apps.isEmpty {
                    nothingLeft
                }
                ForEach(apps) { group in
                    HStack(alignment: .top, spacing: 8) {
                        selectionToggle(for: group).padding(.top, 22)
                        RemnantCard(
                            group: group, isOpen: opened.contains(group.id),
                            isScanning: model.isScanning,
                            toggle: { toggle(group.id) }, finish: { open(group) }
                        )
                    }
                    .padding(.bottom, 8)
                }
                if !unknowns.isEmpty {
                    unknownTitle
                        .padding(.top, 20)
                    if showsUnknown {
                        Text("Nobody can be named for these, so they are never counted.")
                            .font(.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                        ForEach(unknowns) { group in
                            HStack(spacing: 8) {
                                selectionToggle(for: group)
                                UnknownRow(
                                    group: group, isScanning: model.isScanning,
                                    readRecovery: {
                                        if let problem = await HelperRoute.authorizeRecoveryRead() {
                                            recoveryReadError = problem
                                        } else {
                                            await model.load(service: service)
                                        }
                                    },
                                    review: { open(group) }
                                )
                            }
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            ListBottomSpacing()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: opened)
        .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: showsUnknown)
    }

    private func toggle(_ id: String) {
        opened.formSymmetricDifference([id])
    }

    private func sectionTitle(_ title: String, count: Int, bytes: Int64, sizeIsKnown: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.brimGroupTitle)
                .foregroundStyle(Palette.ink)
            if count > 0 {
                Text("\(count) · \(sizeIsKnown ? ByteText.short(bytes) : "Not measured")")
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isHeader)
    }

    private var unknownTitle: some View {
        Button { showsUnknown.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
                    .rotationEffect(.degrees(showsUnknown ? 90 : 0))
                Text("Unknown")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.inkSecondary)
                Text("\(unknowns.count)")
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkTertiary)
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        .accessibilityLabel("Unknown, \(unknowns.count)")
        .accessibilityValue(showsUnknown ? "Expanded" : "Collapsed")
    }

    /// Said where the removed apps would be, before the unknowns.
    private var nothingLeft: some View {
        HStack(spacing: 10) {
            Image(systemName: model.hasUnreadRecoveryCopies ? "questionmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(model.hasUnreadRecoveryCopies ? Palette.inkSecondary : Palette.success)
            Text(model.hasUnreadRecoveryCopies
                ? "No remnants found in checked locations" : "No removed app has left anything")
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Removing

    private func selectionToggle(for group: LeftoverGroup) -> some View {
        Toggle("Select \(group.displayName)", isOn: Binding(
            get: { model.isSelected(group) },
            set: { _ in model.toggle(group) }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(model.isScanning || model.keptGroups.contains(group.id)
            || !group.items.contains(where: \.canBeRemovedByBrim))
    }

    private func openSelection() {
        removedInReview = 0
        review = model.removalIntent(requesterIdentity: NSUserName())
    }

    private func open(_ group: LeftoverGroup) {
        removedInReview = 0
        review = model.removalIntent(for: group, requesterIdentity: NSUserName())
    }

    /// After a removal the check proved: say so, and offer it back.
    private func offerPutBack(_ planId: UUID) {
        let count = removedInReview
        guard count > 0 else { return }
        Task {
            var toast = ToastMessage(
                symbol: "checkmark.circle.fill",
                text: count == 1 ? "Removed 1 item" : "Removed \(count) items"
            )
            if await (try? service.recoverableItems())?.contains(where: { $0.planId == planId }) == true {
                toast.actionTitle = "Put Back"
                toast.action = {
                    Task {
                        do {
                            try await service.undo(planId: planId)
                            recovery.refreshNow()
                            model.reconcileWithDisk()
                        } catch {
                            shell.show(ToastMessage(
                                symbol: "exclamationmark.triangle.fill",
                                text: "Could not put it back"
                            ))
                        }
                    }
                }
            }
            shell.show(toast)
        }
    }
}

private struct LeftoverBatchActions: View {
    let selectedCount: Int
    let canRemoveSelection: Bool
    let canRemoveAll: Bool
    let clear: () -> Void
    let removeSelected: () -> Void
    let removeAll: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(selectedCount) selected")
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
            if selectedCount > 0 {
                Button("Clear", action: clear).buttonStyle(.borderless)
            }
            Spacer()
            Button("Delete All Remnants", action: removeAll)
                .disabled(!canRemoveAll)
                .help("Review all removable items from known removed apps. "
                    + "Unknown items need to be selected separately.")
            Button("Delete Selected", action: removeSelected)
                .capsuleAction(prominent: true)
                .disabled(!canRemoveSelection)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

extension PlanIntent: @retroactive Identifiable {
    public var id: String {
        explicitTargets.map(\.path).joined(separator: "|")
    }
}

/// An app that has gone, as a card: what it was, when it went, and the
/// places it left, folded inside.
private struct RemnantCard: View {
    let group: LeftoverGroup
    let isOpen: Bool
    let isScanning: Bool
    let toggle: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ownerIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.brimRowTitle)
                        .foregroundStyle(Palette.ink)
                    Text(facts)
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                }
                .lineLimit(1)
                .help([group.evidence, group.replacedBy?.sentence].compactMap(\.self).joined(separator: "\n\n"))
                Spacer(minLength: 8)
                Text(group.items.contains { $0.sizeIsKnown == false }
                    ? "Not measured" : ByteText.short(group.totalBytes))
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
                action
            }
            .padding(12)

            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(group.items.count == 1 ? "1 place" : "\(group.items.count) places")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
                .padding(.horizontal, 12)
                .padding(.bottom, isOpen ? 6 : 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, 44)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.items.sorted { $0.size > $1.size }, id: \.url) { item in
                        PlaceRow(item: item)
                    }
                }
                .padding(.leading, 56)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .background(Palette.surface.opacity(0.6), in: .rect(cornerRadius: Metrics.rowRadius + 2))
        .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius + 2).strokeBorder(Palette.well, lineWidth: 0.5))
    }

    /// The app's own icon when Brim saved one, otherwise the kind of place
    /// its largest item is in. Letters on a colour said nothing.
    @ViewBuilder private var ownerIcon: some View {
        if case .monogram = group.ownerIcon,
           let largest = group.items.max(by: { $0.size < $1.size }) {
            LocationIcon(url: largest.url, size: 36)
        } else {
            BrimIcon(source: group.ownerIcon, size: 36)
        }
    }

    @ViewBuilder private var action: some View {
        if group.items.contains(where: \.canBeRemovedByBrim) {
            Button("Finish Removal", action: finish)
                .capsuleAction()
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(isScanning)
        } else {
            // Nothing Brim can take: what is left is for the person.
            RevealButton(urls: group.items.map(\.url), title: "Show in Finder")
                .capsuleAction()
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let removed = group.removedAt {
            parts.append("Removed " + removed.formatted(.dateTime.day().month(.abbreviated)))
        } else {
            parts.append("Removed")
        }
        if let replacement = group.replacedBy {
            parts.append("Replaced by " + replacement.name)
        }
        return parts.joined(separator: " · ")
    }
}

/// One place an app left, inside its card.
private struct PlaceRow: View {
    let item: Leftover

    var body: some View {
        HStack(spacing: 8) {
            LocationIcon(url: item.url, size: 16)
            Text(item.url.lastPathComponent)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(folder)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            Text(item.sizeIsKnown == false ? "Not measured" : ByteText.short(item.size))
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
        }
        .font(.caption)
        .padding(.vertical, 4)
        .help(item.url.path)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("\(item.url.lastPathComponent), in \(folder), "
            + (item.sizeIsKnown == false ? "Not measured" : ByteText.short(item.size)))
    }

    /// The folder it is in, with the home folder as a tilde.
    private var folder: String {
        (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

/// Something nobody can be named for: a flat, quieter row.
private struct UnknownRow: View {
    let group: LeftoverGroup
    let isScanning: Bool
    let readRecovery: () async -> Void
    let review: () -> Void
    @State private var isReadingRecovery = false

    var body: some View {
        HStack(spacing: 10) {
            if let largest = group.items.max(by: { $0.size < $1.size }) {
                LocationIcon(url: largest.url, size: 20)
                    .opacity(0.7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(group.displayName)
                    .foregroundStyle(Palette.inkSecondary)
                if let first = group.items.first {
                    Text((first.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .truncationMode(.head)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Text(group.items.contains { $0.sizeIsKnown == false } ? "Not measured" : ByteText.short(group.totalBytes))
                .monospacedDigit()
                .foregroundStyle(Palette.inkTertiary)
            if group.items.contains(where: \.canBeRemovedByBrim) {
                Button("Review", action: review)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isScanning)
            } else if group.items.contains(where: { $0.url.path == RecoveryCopy.directory }) {
                Button("Read Recovery Copies") {
                    isReadingRecovery = true
                    Task {
                        await readRecovery()
                        isReadingRecovery = false
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isScanning || isReadingRecovery)
            } else {
                RevealButton(urls: group.items.map(\.url), title: "Show")
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .font(.brimFacts)
        .padding(.horizontal, 12)
        .frame(height: Metrics.compactRowHeight + 6)
        .help(group.evidence)
    }
}
