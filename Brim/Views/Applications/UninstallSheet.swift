import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

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
        // A fixed presentation size keeps scrolling from feeding the list's
        // changing ideal size back into AppKit's sheet constraint solver.
        .frame(width: 660, height: 520)
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
                if isFinished {
                    onFinished()
                }
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(model.phase == .executing)
        }
        .padding()
    }

    private var isFinished: Bool {
        if case .verified = model.phase {
            return true
        }
        return false
    }

    /// One sheet serves both jobs, and every sentence in it used to be
    /// written for the uninstall. Resetting an application showed a progress
    /// line saying it was being cleared out, finished on "Nothing is left"
    /// about an application that is still installed on purpose, and offered
    /// a button reading "Authorize & Uninstall" that did not uninstall
    /// anything.
    private var isReset: Bool {
        intentType == .reset
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .preparing:
            ProgressView("Finding app files…")

        case let .failed(reason):
            message(title: "Stopped", detail: reason, isError: true)

        case let .appliedButUnverified(reason):
            message(
                title: isReset ? "Reset, but not checked" : "Removed, but not checked",
                detail: "Verification could not finish: \(reason)",
                isError: false
            )

        case .executing:
            ProgressView(isReset
                ? "Resetting \(application.name)…"
                : "Uninstalling \(application.name)…")

        case let .verified(result):
            verification(result)

        case .ready:
            planList
        }
    }

    private var planList: some View {
        List {
            if model.clearsPrivacyGrants || model.clearsRegistrations {
                Section("System records") {
                    if model.clearsPrivacyGrants {
                        LabeledContent("Privacy permissions", value: "Reset")
                    }
                    if model.clearsRegistrations {
                        LabeledContent("File associations", value: "Remove")
                    }
                }
            }

            Section {
                ForEach(model.removalSteps, id: \.index) { step in
                    UninstallPlanRow(
                        target: step.target, evidence: step.evidence,
                        bytes: step.expectedBytes, disposition: step.effectiveDisposition,
                        kind: step.kind, tier: step.tier,
                        selection: model.isTickedByHand(step.target) ? selection(for: step.target) : nil
                    )
                }
            } header: {
                Text("Selected (\(model.removalSteps.count))")
            }

            if !model.rowsToOffer.isEmpty {
                Section {
                    ForEach(model.rowsToOffer, id: \.target) { row in
                        UninstallPlanRow(
                            target: row.target, evidence: row.evidence ?? row.reason,
                            bytes: row.sizeBytes ?? 0, disposition: nil,
                            kind: nil, tier: row.tier,
                            selection: selection(for: row.target)
                        )
                    }
                } header: {
                    Text("Also include")
                }
            }
        }
        .listStyle(.inset)
    }

    private func selection(for path: String) -> Binding<Bool> {
        Binding(
            get: { model.isTickedByHand(path) },
            set: { ticked in
                Task { await model.setTicked(ticked, path: path) }
            }
        )
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
                    ? "Selected data removed. \(application.name) remains installed."
                    : "All selected items were removed.")
                : (result.reason ?? "Some selected items remain."))
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
        return isReset ? "Reset complete" : "Uninstall complete"
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
                if model.isUpdating {
                    ProgressView("Updating selection…")
                        .controlSize(.small)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        let label = Text("Frees immediately: ").foregroundColor(.secondary)
                        let amount = Text(ByteText.short(plan.immediatelyFreedBytes)).bold().monospacedDigit()
                        Text("\(label)\(amount)")

                        if plan.trashedBytes > 0 {
                            Text("To Trash: \(ByteText.short(plan.trashedBytes))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
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
