import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// Removing a named selection: planned, approved once, applied, and then
/// re-checked.
///
/// Shares `UninstallExecutionModel` with the application uninstall, so the
/// guarantee is the same one: a single authorization for the whole
/// selection, and a verification pass afterwards rather than an assumption.
/// What differs is only what went in, named targets with no owner rather
/// than an identity to discover a footprint from.
///
/// Used by the leftovers sweep and by the background section. Only the two
/// lines at the top differ between them, which is not a reason for two
/// copies of the approval flow.
struct RemovalSheet: View {
    let intent: PlanIntent
    let service: any BrimServiceProtocol
    let title: String
    let subtitle: String
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
        // Checking, then the list, then removing, then the result. Four
        // states that replaced each other instantly, which read as the
        // sheet flickering rather than as it working.
        .animation(.easeOut(duration: 0.18), value: model.phase)
        .task { await model.prepare(intent: intent, service: service) }
    }

    /// Both outcomes that leave the work done, so the button reads "Done"
    /// and the caller is told to refresh either way. A check that could not
    /// run does not put anything back.
    private var isFinished: Bool {
        switch model.phase {
        case .verified, .appliedButUnverified: return true
        default: return false
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2).fontWeight(.bold)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
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
            ProgressView("Checking each item is still where it was…")
        case .failed(let reason):
            VStack(spacing: 6) {
                Text("Stopped").font(.headline).foregroundColor(.red)
                Text(reason).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .padding()
        case .executing:
            ProgressView("Removing…")
        case .appliedButUnverified(let reason):
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.largeTitle).foregroundColor(.secondary)
                Text("Removed, but not checked").font(.headline)
                Text("The removal ran. Brim then went back to confirm each location was "
                     + "clear and the check itself could not finish: \(reason) "
                     + "Nothing has been undone.")
                    .foregroundColor(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
        case .verified(let result):
            // Scrolling, and left aligned when it is an explanation rather
            // than a result. A refusal naming fourteen things ran past the
            // bottom of this panel and was clipped mid-word, with no way to
            // read the rest: the one case where the text matters most was
            // the one case it could not be read in.
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: result.success ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(result.success ? .green : .orange)
                    Text(result.success ? "Nothing is left" : "Some of it is still there")
                        .font(.headline)

                    if result.success {
                        Text("Every location was checked again. All of them are empty.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Text(result.reason ?? "Some of it is still on disk.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }

                    if let explanation = model.spaceExplanation {
                        Label(explanation, systemImage: "clock.arrow.circlepath")
                            .font(.caption).foregroundColor(.orange)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                }
                .padding()
            }
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
                        Text(ByteText.short(step.expectedBytes))
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
                    // Zero is a real answer here and a common one. A set of
                    // broken symlinks takes no space at all, so "Frees now:
                    // Empty" is accurate and reads like a fault. Saying what
                    // is being removed instead keeps the honest number and
                    // stops it looking like nothing is going to happen.
                    if plan.immediatelyFreedBytes > 0 {
                        Text("Frees now: ").foregroundColor(.secondary)
                        + Text(ByteText.short(plan.immediatelyFreedBytes))
                            .fontWeight(.bold).monospacedDigit()
                    } else {
                        Text("Frees no space: these take up none")
                            .foregroundColor(.secondary)
                    }
                    if plan.trashedBytes > 0 {
                        Text("\(ByteText.short(plan.trashedBytes)) goes to the Trash, where you can still get it back")
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
