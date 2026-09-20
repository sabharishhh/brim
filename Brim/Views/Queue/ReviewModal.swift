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

    /// One planned finding: either the plan we will execute, or why we could not plan it.
    private struct PlannedFinding: Identifiable {
        let id: UUID
        let title: String
        let plan: Plan?
        let failure: String?
    }

    @State private var planned: [PlannedFinding] = []
    @State private var isLoading = true
    @State private var isExecuting = false
    @State private var progressLabel: String?
    @State private var errorMessage: String?

    private var executablePlans: [Plan] {
        planned.compactMap(\.plan).filter { !$0.steps.isEmpty }
    }

    private var totalBytes: Int64 {
        executablePlans.reduce(0) { $0 + $1.expectedTotalBytes }
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
                        if let failure = entry.failure {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .foregroundColor(.secondary)
                        } else if let plan = entry.plan, plan.steps.isEmpty {
                            Text("Nothing to remove — safety checks excluded every item.")
                                .foregroundColor(.secondary)
                        } else if let plan = entry.plan {
                            ForEach(stepRows(of: plan)) { row in
                                stepRow(row.step)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    /// Step indices restart at 0 in every plan, so a plain `id: \.index` would
    /// collide across sections and make every section render the first plan's
    /// steps. Qualify each row with its plan.
    private struct StepRow: Identifiable {
        let id: String
        let step: Step
    }

    private func stepRows(of plan: Plan) -> [StepRow] {
        plan.steps.map { StepRow(id: "\(plan.planId)-\($0.index)", step: $0) }
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
            .disabled(isLoading || isExecuting || executablePlans.isEmpty)
        }
        .padding()
    }

    // MARK: - Work

    private func generatePlans() async {
        var results: [PlannedFinding] = []

        for (offset, finding) in findings.enumerated() {
            progressLabel = "Planning \(offset + 1) of \(findings.count): \(finding.title)"

            let identity = finding.leftover.potentialOwner ?? Identity(bundleID: nil, name: finding.title)
            let intent = PlanIntent(
                type: .uninstall,
                subjectIdentity: identity,
                requesterKind: "ui",
                requesterIdentity: NSUserName(),
                specificTarget: finding.leftover.url
            )

            do {
                let plan = try await service.plan(intent: intent)
                results.append(PlannedFinding(id: finding.id, title: finding.title, plan: plan, failure: nil))
            } catch {
                results.append(PlannedFinding(id: finding.id, title: finding.title, plan: nil, failure: error.localizedDescription))
            }
        }

        planned = results
        progressLabel = nil
        isLoading = false
    }

    private func executePlans() async {
        isExecuting = true
        defer { isExecuting = false }

        var completed = Set<UUID>()

        for entry in planned {
            guard let plan = entry.plan, !plan.steps.isEmpty else { continue }
            progressLabel = "Removing \(entry.title)..."

            do {
                let token = try await service.requestApproval(planId: plan.planId, requesterIdentity: NSUserName())
                try await service.apply(planId: plan.planId, token: token)
                completed.insert(entry.id)
            } catch {
                // Report what failed, but keep whatever already succeeded.
                progressLabel = nil
                errorMessage = "\(entry.title): \(error.localizedDescription)"
                onComplete(completed)
                return
            }
        }

        progressLabel = nil
        dismiss()
        onComplete(completed)
    }
}
