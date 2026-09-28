import BrimCore
import SwiftUI

/// What the capability search checked for one app, behind the review's
/// Search details button.
struct SearchDetailsView: View {
    let report: CapabilitySearchReport
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("Back to Review", action: onBack)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .padding()
            List {
                ForEach(report.checks) { check in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(check.capability.title)
                        Text("\(declarationText(check.declaration)) · \(coverageText(check.coverage))")
                            .font(.caption).foregroundColor(.secondary)
                        if check.coverage.available {
                            Text("\(check.registrations.count + check.locations.count) found")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if check.declaration == .declared || !check.registrations.isEmpty || check.followUp != nil {
                            if let tier = check.removalTier {
                                Text(removalText(tier))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            if let followUp = check.followUp {
                                Text(followUp.sentence)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        ForEach(check.locations, id: \.self) { path in
                            Text(path).font(.caption2).foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                ForEach(report.signatureCoverage.indices, id: \.self) { index in
                    if let limitation = report.signatureCoverage[index].limitation {
                        LabeledContent("Signature", value: limitation)
                    }
                }
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
        case .destructiveOnly: "macOS clears this after removal"
        case .detectableOnly: "Requires another action"
        }
    }
}
