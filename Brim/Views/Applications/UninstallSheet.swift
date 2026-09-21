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
                    type: .uninstall,
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
            VStack(alignment: .leading, spacing: 3) {
                Text("Uninstall \(application.name)")
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

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .preparing:
            ProgressView("Finding everything this app has left behind…")

        case .failed(let reason):
            message(title: "Could not continue", detail: reason, isError: true)

        case .executing:
            ProgressView("Removing \(application.name)…")

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
                        "Accessibility, screen recording and other permissions macOS holds for this app "
                        + "are cleared first, while the app is still present. After removal they can no "
                        + "longer be reached.",
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
                        "The app's Launch Services registration is retracted after the bundle is "
                        + "removed, so it stops appearing in \"Open With\" and no longer claims its "
                        + "document types. Deleting an app does not do this on its own.",
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
                            Text(ByteCountFormatter.string(fromByteCount: step.expectedBytes, countStyle: .file))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 1)
                }
            } header: {
                Text("\(model.removalSteps.count) \(model.removalSteps.count == 1 ? "location" : "locations") found from the app's identity")
            }
        }
        .listStyle(.inset)
    }

    private func verification(_ result: VerificationResult) -> some View {
        VStack(spacing: 10) {
            Image(systemName: result.success ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(result.success ? .green : .orange)

            Text(result.success ? "Verified — nothing remains" : "Removed, but not everything is gone")
                .font(.headline)

            // The proof, not a reassurance: the targets were re-checked after
            // removal and this is what the check found.
            Text(result.success
                 ? "Brim re-checked every location it removed and found none of them still present."
                 : (result.reason ?? "Some targets are still present."))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if result.recoveredBytes > 0 {
                Text("\(ByteCountFormatter.string(fromByteCount: result.recoveredBytes, countStyle: .file)) freed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
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
                    + Text(ByteCountFormatter.string(fromByteCount: plan.immediatelyFreedBytes, countStyle: .file))
                        .fontWeight(.bold)
                        .monospacedDigit()

                    if plan.trashedBytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: plan.trashedBytes, countStyle: .file)) moves to the Trash — recoverable")
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
                Button("Authorize & Uninstall") {
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
