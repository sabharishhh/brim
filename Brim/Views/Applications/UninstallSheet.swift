import SwiftUI
import BrimCore
import BrimProtocol
import BrimUI

/// The deep uninstall, shown before it happens and proven after.
///
/// Unlike the Review Queue sheet, nothing here names a path. The plan is
/// built from the application's identity alone, so what the user sees is
/// what the evidence engine discovered — and after applying, the sheet
/// reports the re-check rather than simply closing.
struct UninstallSheet: View {
    let application: InstalledApplication
    let service: any BrimServiceProtocol
    /// Uninstall removes the application and everything it wrote. Reset
    /// keeps the application and its licence and removes the state, so
    /// it starts as if new. One sheet for both, because the review and
    /// the approval are identical and only the plan differs.
    var intentType: IntentType = .uninstall
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
        .frame(minWidth: 580, idealWidth: 660, minHeight: 420, idealHeight: 520)
        .task {
            // Identity only — no specific targets. This is the difference
            // between uninstalling an application and tidying a folder.
            await model.prepare(
                intent: PlanIntent(
                    type: intentType,
                    subjectIdentity: application.identity,
                    requesterKind: "ui",
                    requesterIdentity: NSUserName()
                ),
                service: service
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            AppIconView(url: application.url, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(intentType == .reset ? "Reset" : "Uninstall") \(application.name)")
                    .font(.title2)
                    .fontWeight(.bold)
                if let bundleID = application.identity.bundleID {
                    Text(bundleID)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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

    private var isFinished: Bool {
        if case .verified = model.phase { return true }
        return false
    }

    /// One sheet serves both jobs, and every sentence in it used to be
    /// written for the uninstall. Resetting an application showed a progress
    /// line saying it was being cleared out, finished on "Nothing is left"
    /// about an application that is still installed on purpose, and offered
    /// a button reading "Authorize & Uninstall" that did not uninstall
    /// anything.
    private var isReset: Bool { intentType == .reset }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .preparing:
            ProgressView("Looking for everywhere this app has written…")

        case .failed(let reason):
            message(title: "Stopped", detail: reason, isError: true)

        case .appliedButUnverified(let reason):
            message(
                title: isReset ? "Reset, but not checked" : "Removed, but not checked",
                detail: "The plan ran. Brim then went back to confirm every location was "
                      + "clear and the check itself could not finish: \(reason) "
                      + "Nothing has been undone. Open \(application.name) in the "
                      + "Applications list to look again.",
                isError: false
            )

        case .executing:
            ProgressView(isReset
                        ? "Putting \(application.name) back to how it started…"
                        : "Clearing out \(application.name)…")

        case .verified(let result):
            verification(result)

        case .ready:
            planList
        }
    }

    private var planList: some View {
        List {
            if model.clearsPrivacyGrants {
                Section {
                    Label(
                        "Accessibility, screen recording and the rest get cleared first, while the app "
                        + "is still here. Once it goes, macOS will not let anyone reach them again.",
                        systemImage: "hand.raised"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                } header: {
                    Text("Privacy permissions")
                }
            }

            if model.clearsRegistrations {
                Section {
                    Label(
                        "After the app itself goes, Brim tells macOS to forget it, so it stops turning "
                        + "up in \"Open With\" and stops claiming your files. Dragging an app to the "
                        + "Trash never does this.",
                        systemImage: "app.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                } header: {
                    Text("System registrations")
                }
            }

            Section {
                ForEach(model.removalSteps, id: \.index) { step in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.evidence)
                            .font(.callout)
                        HStack(spacing: 6) {
                            Text(step.target)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .truncationMode(.middle)
                                .lineLimit(1)

                            Label(
                                step.effectiveDisposition == .delete ? "Deleted permanently" : "To Trash",
                                systemImage: step.effectiveDisposition == .delete ? "trash.slash" : "arrow.uturn.backward"
                            )
                            .font(.caption2)
                            .foregroundColor(step.effectiveDisposition == .delete ? .orange : .secondary)

                            Spacer()
                            Text(ByteText.short(step.expectedBytes))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 1)
                }
            } header: {
                Text("\(model.removalSteps.count) \(model.removalSteps.count == 1 ? "place" : "places") Brim traced back to this app")
            }
        }
        .listStyle(.inset)
    }

    private func verification(_ result: VerificationResult) -> some View {
        VStack(spacing: 10) {
            Image(systemName: result.success ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(result.success ? .green : .orange)

            Text(headline(for: result))
                .font(.headline)

            // The proof, not a reassurance: the targets were re-checked after
            // removal and this is what the check found.
            Text(result.success
                 ? (isReset
                    ? "Brim went back to every location it cleared. The settings and state are "
                    + "gone and \(application.name) is still installed."
                    : "Brim went back to every location it touched. All of them are empty.")
                 : (result.reason ?? "Some of it is still on disk."))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if result.recoveredBytes > 0 {
                Text("\(ByteText.short(result.recoveredBytes)) freed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            if let explanation = model.spaceExplanation {
                Label(explanation, systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundColor(.orange)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
    }

    private func headline(for result: VerificationResult) -> String {
        guard result.success else { return "Something is still there" }
        return isReset ? "Back to how it started" : "Nothing is left"
    }

    private func message(title: String, detail: String, isError: Bool) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline).foregroundColor(isError ? .red : .primary)
            Text(detail).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if case .ready = model.phase, let plan = model.plan {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Frees now: ")
                        .foregroundColor(.secondary)
                    + Text(ByteText.short(plan.immediatelyFreedBytes))
                        .fontWeight(.bold)
                        .monospacedDigit()

                    if plan.trashedBytes > 0 {
                        Text("\(ByteText.short(plan.trashedBytes)) goes to the Trash, where you can still get it back")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if model.phase == .executing {
                ProgressView().controlSize(.small).padding(.trailing, 4)
            }

            if !isFinished {
                Button(isReset ? "Approve and reset" : "Approve and uninstall") {
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
