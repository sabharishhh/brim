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
                    // Formatted once, when the record was made. Doing it
                    // here meant building a `Date.FormatStyle` per row per
                    // frame, which is what made this list heavy to scroll.
                    Text(record.occurred)

                    if let reason = record.unavailableReason {
                        Text("·")
                        Text(reason)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Only where it would do something. This was a Button on every
            // row with `.disabled(!record.canUndo)`, and on this Mac the
            // header read "39 removals, 0 can be undone": thirty-nine
            // bezels, tint colours, hover regions and focus rings drawn per
            // frame for thirty-nine controls that did nothing. It is the
            // single reason this list was rough to scroll, and a disabled
            // control on every row is what the Background footer already
            // refuses to do.
            //
            // The row says why instead, which it was saying anyway: "No
            // longer in the Trash", or "Deleted permanently".
            if model.undoingPlanIds.contains(record.id) {
                ProgressView().controlSize(.small)
            } else if record.canUndo {
                Button("Undo") {
                    Task { await model.undo(record) }
                }
            }
        }
        .padding(.vertical, 4)
        // `.ignore`, not `.combine`: there is a written label, so merging
        // the children first is work whose result is thrown away.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(record.spoken)
    }

    // `spokenLabel` moved to `RemovalRecord`, where it is built once when
    // the record is made rather than on every pass of every row. The
    // wording, and the incident behind it, travelled with it.
}
