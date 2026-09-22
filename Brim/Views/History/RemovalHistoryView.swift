import SwiftUI
import BrimCore
import BrimUI

/// Past removals, and the one place undo is offered.
struct RemovalHistoryView: View {
    @ObservedObject var model: RemovalHistoryModel
    @ObservedObject var recovery: RecoveryStatusModel
    @SwiftUI.Environment(\.brimService) private var service

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let errorMessage = model.errorMessage {
                errorBar(errorMessage)
                Divider()
            }

            content
        }
        .task { await model.load(service: service) }
        .task {
            // Recoverability changes when the Trash does, so History follows
            // it for as long as the view is on screen.
            await recovery.start(service: service)
        }
        .onChange(of: recovery.items) { _, _ in
            Task { await model.reload() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("History")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(subtitle)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            Button {
                Task { await model.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh history")
        }
        .padding()
    }

    private var subtitle: String {
        if model.isLoading { return "Loading…" }
        let undoable = model.records.filter(\.canUndo).count
        if model.records.isEmpty { return "Nothing removed yet" }
        return "\(model.records.count) \(model.records.count == 1 ? "removal" : "removals") · \(undoable) can be undone"
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .font(.subheadline)
            Spacer()
            Button("Dismiss") { model.errorMessage = nil }
                .buttonStyle(.link)
        }
        .foregroundColor(.orange)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.records.isEmpty && !model.isLoading {
            VStack(spacing: 6) {
                Text("No removals yet")
                    .font(.headline)
                Text("Everything you remove with Brim is listed here, newest first.")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.records) { record in
                row(record)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ record: RemovalRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .fontWeight(.medium)

                HStack(spacing: 6) {
                    Text("\(record.itemCount) \(record.itemCount == 1 ? "item" : "items")")
                    Text("·")
                    // ByteText, like everywhere else. The raw formatter
                    // writes "Zero KB" for an empty removal, and two
                    // spellings of the same quantity in one product is the
                    // thing that makes people distrust all of them.
                    Text(ByteText.short(record.bytes))
                        .monospacedDigit()
                    Text("·")
                    Text(record.plan.createdAt, format: .dateTime.month().day().hour().minute())

                    if let reason = record.unavailableReason {
                        Text("·")
                        Text(reason)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if model.undoingPlanIds.contains(record.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Undo") {
                    Task { await model.undo(record) }
                }
                .disabled(!record.canUndo)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel(for: record))
    }

    /// One sentence per fact, assembled rather than concatenated.
    ///
    /// The previous version glued the reason on with `?? ""`, so a record
    /// that cannot be undone and carries no stored reason was read out as
    /// "Figma, 3 items, 40 MB. , cannot be undone." It also said "items" for
    /// a removal of one, while the row beside it said "item".
    private func spokenLabel(for record: RemovalRecord) -> String {
        let items = "\(record.itemCount) \(record.itemCount == 1 ? "item" : "items")"
        var parts = ["\(record.name), \(items), \(ByteText.short(record.bytes))"]

        if record.canUndo {
            parts.append("Can be undone")
        } else if let reason = record.unavailableReason, !reason.isEmpty {
            parts.append("\(reason), so it cannot be undone")
        } else {
            parts.append("Cannot be undone")
        }
        return parts.joined(separator: ". ") + "."
    }
}
