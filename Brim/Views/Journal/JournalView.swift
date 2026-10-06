import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// What happened on this Mac, newest first: what Brim removed and whether
/// it can still be put back, and what was installed.
///
/// Installs come only from snapshots. An app that was here the first time
/// Brim looked has no install to show, and Spotlight's date added moves
/// on every update, so it cannot stand in.
struct JournalView: View {
    @ObservedObject var model: RemovalHistoryModel
    @ObservedObject var recovery: RecoveryStatusModel
    @ObservedObject var applications: ApplicationsModel
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Built when the records or the apps change, not while drawing.
    @State private var checkedResult: VerificationResult?
    @State private var checkedPlan: Plan?
    @State private var checkingPlanID: UUID?
    @State private var checkError = ""
    @State private var showsCheckError = false
    @State private var groups: [ItemGroup<JournalEntry>] = []
    @State private var confirmsClear = false
    /// The removals whose Trash items the person is being asked to delete.
    @State private var trashRequest: [RemovalRecord] = []
    @State private var trashError: String?

    var body: some View {
        VStack(spacing: 0) {
            // A Put Back's outcome is shown beside its record, once, rather
            // than in a banner above a list the person has scrolled.
            content
        }
        .pageTitle("Journal")
        .toolbar { journalActions }
        .focusedSceneValue(\.pageActions, menuActions)
        .sheet(item: $checkedResult) { result in
            RemovalVerificationSheet(result: result, plan: checkedPlan)
        }
        .alert("Could not check removal", isPresented: $showsCheckError) {
            Button("OK", role: .cancel) {}
        } message: { Text(checkError) }
        .alert("Clear the Journal?", isPresented: $confirmsClear) {
            Button("Clear", role: .destructive) { model.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything listed so far leaves the Journal. Removals you can still put back stay.")
        }
        .alert(trashTitle, isPresented: asksToDelete) {
            Button("Delete", role: .destructive) { deleteFromTrash(trashRequest) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They can no longer be put back. Nothing else in the Trash is touched.")
        }
        .alert("Could not delete from the Trash", isPresented: showsTrashError) {
            Button("OK", role: .cancel) {}
        } message: { Text(trashError ?? "") }
        .task { await model.load(service: service) }
        // Listing the apps writes the snapshot an install is read from.
        .task {
            await applications.loadIfNeeded(service: service)
            await model.reload()
            await recheckRemovals()
        }
        // Whether something can be put back changes when the Trash does.
        .task { await recovery.start(service: service) }
        .onChange(of: recovery.items) { _, _ in
            Task {
                await model.reload()
                await recheckRemovals()
            }
        }
        .task(id: Signature(model.visibleRecords, installs: model.visibleInstalls.count)) {
            let entries = JournalTimeline.entries(records: model.visibleRecords, installs: model.visibleInstalls)
            withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
                groups = JournalTimeline.groups(entries)
            }
        }
    }

    /// What the timeline is rebuilt on: which removals, whether each can
    /// still be put back, and how many installs. Not the records themselves,
    /// whose equality compares every step of every plan on each update.
    private struct Signature: Equatable {
        let records: [UUID]
        let putBack: [Bool]
        let installs: Int

        init(_ records: [RemovalRecord], installs: Int) {
            self.records = records.map(\.id)
            putBack = records.map(\.canUndo)
            self.installs = installs
        }
    }

    // MARK: - Header

    /// Emptying the Trash and clearing the Journal, as two buttons in the
    /// toolbar beside Check Again. They sat in a More menu, where neither
    /// could be seen until it was looked for. Each still asks first.
    @ToolbarContentBuilder
    private var journalActions: some ToolbarContent {
        // Their own group, apart from Check Again: a refresh and two actions
        // that delete were one capsule.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Empty Removed Items from Trash", systemImage: "trash") {
                trashRequest = model.records.filter(\.canUndo)
            }
            .disabled(!model.records.contains(where: \.canUndo))
            .help("Empty removed items from the Trash")
            Button("Clear Journal", systemImage: "eraser") { confirmsClear = true }
                .disabled(!model.canClear)
                .help("Clear the Journal")
        }
    }

    /// The same two commands for the Action menu, when there is something
    /// for them to do.
    private var menuActions: [FocusedAction<Void>] {
        var actions: [FocusedAction<Void>] = []
        if model.records.contains(where: \.canUndo) {
            actions.append(FocusedAction(name: "Empty Removed Items from Trash…") { _ in
                trashRequest = model.records.filter(\.canUndo)
            })
        }
        if model.canClear {
            actions.append(FocusedAction(name: "Clear Journal…") { _ in confirmsClear = true })
        }
        return actions
    }

    /// Names one removal, counts several, and says how much goes.
    private var trashTitle: String {
        let bytes = trashRequest.reduce(Int64(0)) { $0 + $1.bytes }
        let what = trashRequest.count == 1 ? "\(trashRequest[0].name)'s items"
            : "items from \(trashRequest.count) removals"
        return bytes > 0 ? "Delete \(what), \(ByteText.short(bytes)), from the Trash?"
            : "Delete \(what) from the Trash?"
    }

    private var asksToDelete: Binding<Bool> {
        Binding(get: { !trashRequest.isEmpty }, set: { asked in
            if !asked {
                trashRequest = []
            }
        })
    }

    private var showsTrashError: Binding<Bool> {
        Binding(get: { trashError != nil }, set: { shown in
            if !shown {
                trashError = nil
            }
        })
    }

    private func deleteFromTrash(_ records: [RemovalRecord]) {
        Task {
            await model.deleteFromTrash(records)
            await recovery.refresh(service: service)
            trashError = model.errorMessage
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private var content: some View {
        if model.isLoading, groups.isEmpty {
            SkeletonRows(showsTick: false)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if groups.isEmpty {
            EmptyState(symbol: "book.closed", title: "Nothing yet", message: "Removals and installs appear here.")
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        // The group's title as its first row, not a pinned header:
                        // a pinned header is drawn on its own band with a rule under it.
                        Group {
                            Text(group.title)
                                .font(.brimDayHeader)
                                .foregroundStyle(Palette.ink)
                                // 16 and the list's own 8: under the title.
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)

                        ForEach(group.items) { entry in
                            JournalRow(
                                entry: entry,
                                isPuttingBack: isPuttingBack(entry),
                                outcome: outcome(entry),
                                recheck: secondLook(entry),
                                putBack: { putBack(entry) },
                                review: { review(entry) }
                            )
                            .contextMenu {
                                if case let .removed(record) = entry.event {
                                    Button("Check Removal", systemImage: "arrow.clockwise") {
                                        recheck(record.plan)
                                    }
                                    .disabled(checkingPlanID != nil)
                                    if record.canUndo {
                                        Button("Delete from Trash…", systemImage: "trash") {
                                            trashRequest = [record]
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                            .listRowSeparator(.hidden)
                            .transition(.brimRow(reduceMotion: reduceMotion))
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
                ListBottomSpacing()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func recheck(_ plan: Plan) {
        guard checkingPlanID == nil else { return }
        checkingPlanID = plan.planId
        Task {
            defer { checkingPlanID = nil }
            do {
                let result = try await service.verify(planId: plan.planId)
                checkedPlan = plan
                checkedResult = result
            } catch {
                checkError = error.localizedDescription
                showsCheckError = true
            }
        }
    }

    /// Every confirmed removal, looked at again by path. Cheap: the last
    /// hundred removals are a few thousand `lstat` calls.
    private func recheckRemovals() async {
        let installed = Set(applications.applications.compactMap(\.identity.bundleID))
        await model.recheck(installed: installed)
    }

    /// What the second look found, unless a Put Back just changed it.
    private func secondLook(_ entry: JournalEntry) -> RemovalRecheck.State? {
        guard case let .removed(record) = entry.event, model.putBackOutcomes[record.id] == nil else { return nil }
        return model.rechecks[record.id]
    }

    private func review(_ entry: JournalEntry) {
        guard case let .removed(record) = entry.event else { return }
        recheck(record.plan)
    }

    private func isPuttingBack(_ entry: JournalEntry) -> Bool {
        guard case let .removed(record) = entry.event else { return false }
        return model.undoingPlanIds.contains(record.id)
    }

    private func outcome(_ entry: JournalEntry) -> RemovalHistoryModel.PutBackOutcome? {
        guard case let .removed(record) = entry.event else { return nil }
        return model.putBackOutcomes[record.id]
    }

    private func putBack(_ entry: JournalEntry) {
        guard case let .removed(record) = entry.event else { return }
        Task { await model.undo(record) }
    }
}
