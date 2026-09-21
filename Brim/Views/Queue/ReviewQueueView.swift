import SwiftUI
import BrimUI

struct ReviewQueueView: View {
    @Binding var navigationSelection: NavigationItem?

    @ObservedObject private var viewModel: ReviewQueueViewModel
    @ObservedObject private var recovery: RecoveryStatusModel
    @ObservedObject private var fullDiskAccess: FullDiskAccessModel

    init(selection: Binding<NavigationItem?>, models: SectionModels) {
        self._navigationSelection = selection
        self.viewModel = models.review
        self.recovery = models.recovery
        self.fullDiskAccess = models.fullDiskAccess
    }
    @State private var selection = Set<UUID>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.brimService) private var service
    
    @State private var reviewRequest: ReviewRequest?

    /// Carries the selection into the sheet. Using `.sheet(item:)` rather than
    /// `.sheet(isPresented:)` guarantees the modal is built with the findings
    /// that were selected at the moment the sheet was requested.
    struct ReviewRequest: Identifiable {
        let id = UUID()
        let findings: [Finding]
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Queue")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    if viewModel.isPopulating {
                        Text("Scanning... \(viewModel.totalCount) items so far")
                            .foregroundColor(.secondary)
                    } else if let errorMessage = viewModel.errorMessage {
                        Text("Scan failed: \(errorMessage)")
                            .foregroundColor(.red)
                    } else {
                        Text("\(viewModel.totalCount) items found")
                            .foregroundColor(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                
                Spacer()
                
                Button {
                    Task { await viewModel.populateProgressively(service: service) }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.isPopulating)
                .accessibilityLabel("Rescan for leftovers")
                
                if !selection.isEmpty {
                    Button(role: .destructive) {
                        removeSelected()
                    } label: {
                        Text("Review Selected (\(selection.count))")
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .accessibilityLabel("Review \(selection.count) selected items")
                }
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(ByteCountFormatter.string(fromByteCount: viewModel.totalBytes, countStyle: .file))
                        .font(.title2)
                        .monospacedDigit()
                        .fontWeight(.bold)
                    
                    Text("Total footprint")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Total footprint is \(ByteCountFormatter.string(fromByteCount: viewModel.totalBytes, countStyle: .file))")
            }
            .padding()
            
            if !fullDiskAccess.isGranted {
                fullDiskAccessBanner
                Divider()
            }

            if !recovery.isEmpty {
                recoveryBanner
                Divider()
            }
            
            BrimTableView(
                items: viewModel.findings,
                columns: [
                    BrimTableColumn(id: "Name", title: "Name", minWidth: 150) { item in
                        Text(item.title).fontWeight(.medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("\(item.title). \(item.category). Confidence: \(confidenceString(for: item.confidence)). Size: \(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))")
                    },
                    BrimTableColumn(id: "Category", title: "Category", minWidth: 100, maxWidth: 150) { item in
                        Text(item.category).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityHidden(true)
                    },
                    BrimTableColumn(id: "Path", title: "Path", minWidth: 200) { item in
                        Text(item.path).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .truncationMode(.middle)
                            .accessibilityHidden(true)
                    },
                    BrimTableColumn(id: "Confidence", title: "Confidence", width: 100, minWidth: 100, maxWidth: 120) { item in
                        confidenceView(for: item.confidence)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityHidden(true)
                    },
                    BrimTableColumn(id: "Size", title: "Size", width: 80, minWidth: 80, maxWidth: 100) { item in
                        Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                ],
                selection: $selection
            )
        }
        .task {
            if viewModel.findings.isEmpty {
                await viewModel.populateProgressively(service: service)
            }
        }
        .task {
            // Watches the Trash for as long as this view is on screen, and is
            // torn down automatically when the task is cancelled.
            await recovery.start(service: service)
        }
        .onAppear { fullDiskAccess.startObserving() }
        .onDisappear { fullDiskAccess.stopObserving() }
        .focusedSceneValue(\.removeSelectedAction, removeSelected)
        .sheet(item: $reviewRequest) { request in
            ReviewModal(
                findings: request.findings,
                service: service,
                onComplete: { completedIDs in
                    withAnimation(reduceMotion ? nil : .default) {
                        viewModel.removeItems(with: completedIDs)
                        selection.subtract(completedIDs)
                    }
                    // Do not wait for the file-system event to come back.
                    recovery.refreshNow()
                }
            )
        }
    }
    
    private var recoveryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundColor(.secondary)

            Text("\(recovery.items.count) \(recovery.items.count == 1 ? "removal" : "removals") still recoverable from the Trash")
                .font(.subheadline)

            Text(ByteCountFormatter.string(fromByteCount: recovery.totalBytes, countStyle: .file))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundColor(.secondary)

            Spacer()

            Text("Freed when you empty the Trash")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Review in History") {
                navigationSelection = .history
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(recovery.items.count) removals still recoverable from the Trash, \(ByteCountFormatter.string(fromByteCount: recovery.totalBytes, countStyle: .file)), freed when you empty the Trash")
    }

    /// Full Disk Access is a precondition, not a refinement: without it Brim
    /// cannot see most of an application's footprint, so its findings are
    /// incomplete rather than merely delayed. Stated plainly and once, at the
    /// top of the queue, rather than nagged.
    private var fullDiskAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.lock")
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("Full Disk Access required")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if fullDiskAccess.hasRequested {
                    Text("Switch on Brim in the list, then quit and open it again. macOS only picks the change up on a fresh start.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Brim cannot see most of an app's footprint without it, so these results are incomplete. Trash changes are also noticed on a delay.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button("Open Settings") {
                fullDiskAccess.requestAccess()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Full Disk Access required. Brim cannot see most of an app's footprint without it, so these results are incomplete.")
    }

    private func removeSelected() {
        let selected = viewModel.findings.filter { selection.contains($0.id) }
        guard !selected.isEmpty else { return }
        reviewRequest = ReviewRequest(findings: selected)
    }
    
    private func confidenceString(for confidence: FindingConfidence) -> String {
        switch confidence {
        case .guaranteed: return "High"
        case .high: return "Medium"
        case .heuristic: return "Heuristic"
        }
    }
    
    @ViewBuilder
    private func confidenceView(for confidence: FindingConfidence) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(confidence == .guaranteed ? Color.primary : (confidence == .high ? Color.secondary : Color.gray.opacity(0.5)))
                .frame(width: 6, height: 6)
            
            Text(confidenceString(for: confidence))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// Global focused action pattern for menu commands
struct RemoveSelectedActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var removeSelectedAction: (() -> Void)? {
        get { self[RemoveSelectedActionKey.self] }
        set { self[RemoveSelectedActionKey.self] = newValue }
    }
}
