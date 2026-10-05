import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// One event: the app's icon, what happened, and when.
struct JournalRow: View {
    let entry: JournalEntry
    let isPuttingBack: Bool
    let outcome: RemovalHistoryModel.PutBackOutcome?
    let putBack: () -> Void
    @State private var showsFailure = false
    /// Denser rows, from View ▸ Compact Rows.
    @SwiftUI.Environment(\.compactRows) private var compact

    var body: some View {
        HStack(spacing: 12) {
            BrimIcon(source: icon, size: Metrics.rowIcon(compact: compact), badge: isRemoval ? .removed : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                if !compact {
                    Text(facts)
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .lineLimit(1)
            .accessibilityHidden(true)
            Spacer(minLength: 8)
            // Reserved width, so Put Back, its progress and its outcome take
            // turns in one place and the time beside them never moves.
            trailing
                .frame(minWidth: 120, alignment: .trailing)
            Text(entry.time)
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkTertiary)
                .frame(width: 56, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight(compact: compact))
        .rowHighlight(isInspected: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
    }

    private var isRemoval: Bool {
        if case .removed = entry.event {
            return true
        }
        return false
    }

    /// The app's own icon while it is here, the saved one once it is gone,
    /// and a folder for a removal that was not one app.
    private var icon: IconSource {
        switch entry.event {
        case let .installed(url):
            if let url, entry.isPresent {
                return .bundle(url)
            }
            guard let bundleID = entry.bundleID, IconMemory.standard.has(bundleID) else {
                return .monogram(Monogram(name: entry.name))
            }
            return .remembered(bundleID: bundleID)
        case .removed:
            guard let bundleID = entry.bundleID, IconMemory.standard.has(bundleID) else {
                return entry.bundleID == nil ? .symbol(.folder) : .monogram(Monogram(name: entry.name))
            }
            return .remembered(bundleID: bundleID)
        }
    }

    private var facts: String {
        switch entry.event {
        case .installed:
            return "Installed"
        case let .removed(record):
            let items = record.itemCount == 1 ? "1 item" : "\(record.itemCount) items"
            // Broken links take no space, and "Empty" beside a count of
            // items reads as though nothing was there.
            guard record.bytes > 0 else { return "Removed · \(items)" }
            return "Removed · \(items) · \(ByteText.short(record.bytes))"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if case let .removed(record) = entry.event {
            if isPuttingBack {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Putting back").font(.caption).foregroundStyle(Palette.inkSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Putting back")
            } else if outcome == .restored {
                // What actually happened, in place of the button: the files
                // are back where they were.
                Label("Put back", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary, Palette.success)
            } else if case let .failed(reason) = outcome {
                Button {
                    showsFailure = true
                } label: {
                    Label("Could not put back", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.inkSecondary, Palette.caution)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(reason)
                .accessibilityHint("Shows why")
                .popover(isPresented: $showsFailure) {
                    Text(reason)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding()
                        .frame(width: 300, alignment: .leading)
                }
            } else if record.canUndo {
                // Only where it would do something: a disabled button on
                // every row is thirty-nine controls that do nothing.
                Button("Put Back", action: putBack)
                    .capsuleAction()
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            } else if let reason = record.unavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// One sentence for the row, so a reader hears one event rather than
    /// four fragments. Put Back, where there is one, stays its own button.
    private var spoken: String {
        switch entry.event {
        case .installed:
            return "\(entry.name), installed, \(entry.time)"
        case let .removed(record):
            let state = switch outcome {
            case .restored: "put back"
            case let .failed(reason): "could not put back. \(reason)"
            case nil: record.canUndo ? "can be put back" : (record.unavailableReason ?? "")
            }
            return [entry.name, facts, state, entry.time].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }
}
