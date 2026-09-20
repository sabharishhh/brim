import Foundation
import SwiftUI
import BrimProtocol
import BrimCore
import BrimUI

struct ReviewModal: View {
    let findings: [Finding]
    let service: any BrimServiceProtocol
    let onComplete: (Set<UUID>) -> Void

    @SwiftUI.Environment(\.dismiss) private var dismiss

    /// The steps of the single batch plan, grouped under the finding that
    /// asked for them, so the user still reviews the selection item by item.
    private struct PlannedFinding: Identifiable {
        let id: UUID
        let title: String
        let steps: [Step]
        /// Set when the planner produced nothing for this finding's target.
        let excludedReason: String?
    }

    @State private var plan: Plan?
    @State private var planned: [PlannedFinding] = []
    @State private var isLoading = true
    @State private var isExecuting = false
    @State private var progressLabel: String?
    @State private var errorMessage: String?

    private var isExecutable: Bool {
        guard let plan else { return false }
        return !plan.steps.isEmpty
    }

    private var totalBytes: Int64 {
        plan?.expectedTotalBytes ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .frame(minWidth: 560, idealWidth: 640, maxWidth: .infinity,
               minHeight: 360, idealHeight: 480, maxHeight: .infinity)
        .task { await generatePlans() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review & Execute")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("\(findings.count) selected \(findings.count == 1 ? "item" : "items")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(isExecuting)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView(progressLabel ?? "Analyzing selection...")
        } else if let errorMessage {
            message(title: "Could not continue", detail: errorMessage, isError: true)
        } else if planned.isEmpty {
            message(title: "Nothing selected", detail: "Select one or more items in the queue first.", isError: false)
        } else {
            List {
                ForEach(planned) { entry in
                    Section(header: Text(entry.title)) {
                        if let reason = entry.excludedReason {
                            Label(reason, systemImage: "exclamationmark.triangle")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(stepRows(of: entry)) { row in
                                stepRow(row.step)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private struct StepRow: Identifiable {
        let id: String
        let step: Step
    }

    private func stepRows(of entry: PlannedFinding) -> [StepRow] {
        entry.steps.map { StepRow(id: "\(entry.id)-\($0.index)", step: $0) }
    }

    private func stepRow(_ step: Step) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.evidence)
                .font(.body)
            HStack {
                Text(step.target)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: step.expectedBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func message(title: String, detail: String, isError: Bool) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundColor(isError ? .red : .primary)
            Text(detail)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total to reclaim: ")
                    .foregroundColor(.secondary)
                + Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                    .fontWeight(.bold)
                    .monospacedDigit()

                if isExecuting, let progressLabel {
                    Text(progressLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isExecuting {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }

            Button("Authorize & Remove") {
                Task { await executePlans() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLoading || isExecuting || !isExecutable)
        }
        .padding()
    }

    // MARK: - Work

    /// One plan for the whole selection: the user reviews and authorizes the
    /// complete set once, and the approval token is bound to that one plan.
    private func generatePlans() async {
        defer { isLoading = false }

        let identity = batchIdentity()
        let intent = PlanIntent(
            type: .uninstall,
            subjectIdentity: identity,
            requesterKind: "ui",
            requesterIdentity: NSUserName(),
            specificTargets: findings.map(\.leftover.url)
        )

        do {
            let plan = try await service.plan(intent: intent)
            self.plan = plan
            self.planned = group(steps: plan.steps, excluded: plan.excludedItems)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A single selected item keeps its own identity so the authentication
    /// prompt and the plan name it; a mixed selection has no one subject.
    private func batchIdentity() -> Identity {
        if findings.count == 1, let only = findings.first {
            return only.leftover.potentialOwner ?? Identity(bundleID: nil, name: only.title)
        }
        return Identity(bundleID: nil, name: "\(findings.count) selected items")
    }

    /// Attribute each planned step back to the finding that asked for it, so
    /// the sheet still reads item by item.
    private func group(steps: [Step], excluded: [ExcludedItem]) -> [PlannedFinding] {
        findings.map { finding in
            let path = finding.leftover.url.path
            let mine = steps.filter { $0.target == path || $0.target.hasPrefix(path + "/") }

            if mine.isEmpty {
                let reason = excluded.first { $0.target == path || $0.target.hasPrefix(path + "/") }?.reason
                return PlannedFinding(
                    id: finding.id,
                    title: finding.title,
                    steps: [],
                    excludedReason: reason ?? "Nothing to remove — safety checks excluded this item."
                )
            }
            return PlannedFinding(id: finding.id, title: finding.title, steps: mine, excludedReason: nil)
        }
    }

    private func executePlans() async {
        guard let plan else { return }

        isExecuting = true
        defer { isExecuting = false }

        progressLabel = findings.count == 1
            ? "Removing \(findings[0].title)..."
            : "Removing \(findings.count) items..."

        do {
            // One authorization for the whole selection.
            let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
            try await service.apply(planId: plan.planId, token: token)
        } catch {
            progressLabel = nil
            errorMessage = error.localizedDescription
            return
        }

        progressLabel = nil
        // The plan is applied as a unit, so everything it covered is gone.
        let removed = Set(planned.filter { !$0.steps.isEmpty }.map(\.id))
        dismiss()
        onComplete(removed)
    }
}
