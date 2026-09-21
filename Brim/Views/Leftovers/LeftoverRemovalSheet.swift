import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// Removing a selection of leftovers: planned, approved once, applied, and
/// then re-checked.
///
/// Shares `UninstallExecutionModel` with the application uninstall, so the
/// guarantee is the same one — a single authorization for the whole
/// selection, and a verification pass afterwards rather than an assumption.
/// What differs is only what went in: named targets with no owner, instead
/// of an identity to discover a footprint from.
struct LeftoverRemovalSheet: View {
    let intent: PlanIntent
    let service: any BrimServiceProtocol
    let onFinished: () -> Void

    @StateObject private var model = UninstallExecutionModel()
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 400, idealHeight: 480)
        .task { await model.prepare(intent: intent, service: service) }
    }

    private var isFinished: Bool {
        if case .verified = model.phase { return true }
        return false
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Remove leftovers").font(.title2).fontWeight(.bold)
                Text("\(intent.explicitTargets.count) items with no owner on this Mac")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(isFinished ? "Done" : "Cancel") {
                if isFinished { onFinished() }
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(model.phase == .executing)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .preparing:
            ProgressView("Checking each one is still there…")
        case .failed(let reason):
            VStack(spacing: 6) {
                Text("Could not continue").font(.headline).foregroundColor(.red)
                Text(reason).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .padding()
        case .executing:
            ProgressView("Removing…")
        case .verified(let result):
            VStack(spacing: 10) {
                Image(systemName: result.success ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(result.success ? .green : .orange)
                Text(result.success ? "Verified — nothing remains" : "Removed, but not everything is gone")
                    .font(.headline)
                Text(result.success
                     ? "Brim re-checked every location it removed and found none of them still present."
                     : (result.reason ?? "Some targets are still present."))
                    .foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            }
            .padding()
        case .ready:
            List(model.removalSteps, id: \.index) { step in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(URL(fileURLWithPath: step.target).lastPathComponent).font(.callout)
                        Spacer()
                        Label(
                            step.effectiveDisposition == .delete ? "Deleted permanently" : "To Trash",
                            systemImage: step.effectiveDisposition == .delete ? "trash.slash" : "arrow.uturn.backward"
                        )
                        .font(.caption2)
                        .foregroundColor(step.effectiveDisposition == .delete ? .orange : .secondary)
                        Text(ByteCountFormatter.string(fromByteCount: step.expectedBytes, countStyle: .file))
                            .font(.caption).foregroundColor(.secondary).monospacedDigit()
                    }
                    Text(step.target)
                        .font(.caption).foregroundColor(.secondary)
                        .truncationMode(.middle).lineLimit(1)
                }
                .padding(.vertical, 1)
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            if case .ready = model.phase, let plan = model.plan {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Frees now: ").foregroundColor(.secondary)
                    + Text(ByteCountFormatter.string(fromByteCount: plan.immediatelyFreedBytes, countStyle: .file))
                        .fontWeight(.bold).monospacedDigit()
                    if plan.trashedBytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: plan.trashedBytes, countStyle: .file)) moves to the Trash — recoverable")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            if model.phase == .executing {
                ProgressView().controlSize(.small).padding(.trailing, 4)
            }
            if !isFinished {
                Button("Authorize & Remove") {
                    Task { await model.authorize(requesterIdentity: NSUserName()) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canAuthorize)
            }
        }
        .padding()
    }
}
