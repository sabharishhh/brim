import BrimCore
import SwiftUI

/// What the capability search checked for one app, behind the review's
/// Search details button.
struct SearchDetailsView: View {
    let report: CapabilitySearchReport?
    var completeness: ScanCompleteness?
    var staying: [ExcludedItem] = []
    var dockFailure: String?
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("Back to Review", action: onBack)
                .capsuleAction()
                .buttonBorderShape(.capsule)
                .padding()
            List {
                if let completeness, !completeness.isComplete {
                    Section("Search coverage") {
                        ForEach(completeness.unreadable, id: \.self) { Text($0).font(.caption).selectableText() }
                        ForEach(completeness.timedOut, id: \.self) { Text($0).font(.caption).selectableText() }
                    }
                }
                if let dockFailure {
                    Text(dockFailure).font(.caption)
                }
                if !staying.isEmpty {
                    Section("Kept items") {
                        ForEach(staying, id: \.target) { item in
                            LabeledContent(URL(fileURLWithPath: item.target).lastPathComponent, value: item.reason)
                        }
                    }
                }
                ForEach(report?.checks ?? []) { check in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(check.capability.title)
                        Text("\(declarationText(check.declaration)) · \(coverageText(check.coverage))")
                            .font(.caption).foregroundStyle(.secondary)
                        if check.coverage.available {
                            Text("\(check.registrations.count + check.locations.count) found")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if check.declaration == .declared || !check.registrations.isEmpty || check.followUp != nil {
                            if let tier = check.removalTier {
                                Text(removalText(tier))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let followUp = check.followUp {
                                Text(followUp.sentence)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(check.locations, id: \.self) { path in
                            Text(path).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                ForEach(Array((report?.signatureCoverage ?? []).enumerated()), id: \.offset) { _, coverage in
                    if let limitation = coverage.limitation {
                        LabeledContent("Signature", value: limitation)
                    }
                }
                ListBottomSpacing()
            }
            .listStyle(.inset)
        }
    }

    private func declarationText(_ state: CapabilitySurface.DeclarationState) -> String {
        switch state {
        case .declared: "Declared"
        case .notDeclared: "Not declared"
        case .unknown: "Unknown"
        }
    }

    private func coverageText(_ coverage: RegistrationCoverage) -> String {
        coverage.available ? "Checked" : (coverage.absence == .byDesign ? "Unavailable" : "Could not read")
    }

    private func removalText(_ tier: RemovalTier) -> String {
        switch tier {
        case .removable: "Brim can remove this"
        case .destructiveOnly: "No targeted removal"
        case .detectableOnly: "Detected only"
        }
    }
}
