import BrimCore
import BrimProtocol
import SwiftUI

/// The three things a removal can say afterwards, kept apart: checked and
/// gone, declared none by the app, kept by macOS. See `RemovalReport`.
struct RemovalReportView: View {
    let report: RemovalReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                line("Checked, gone", gone)
                if !report.declaredNone.isEmpty {
                    line("Declared none", report.declaredNone.map(\.title).joined(separator: ", "))
                }
                if report.stillThere > 0 {
                    line("Still there", report.stillThere == 1 ? "1 item" : "\(report.stillThere) items")
                }
                if !report.keptByMacOS.isEmpty {
                    line("Kept by macOS", report.keptByMacOS.count == 1 ? "1 item" : "\(report.keptByMacOS.count) items")
                }
            }
            ForEach(report.keptByMacOS, id: \.self) { kept in
                VStack(alignment: .leading, spacing: 1) {
                    Text(kept.what)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.ink)
                    Text(kept.why)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("\(kept.what). \(kept.why)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.opacity(0.5), in: .rect(cornerRadius: Metrics.rowRadius))
    }

    private var gone: String {
        let places = report.checkedGone == 1 ? "1 place" : "\(report.checkedGone.formatted()) places"
        let kinds = report.registrationsChecked.count
        guard kinds > 0 else { return places }
        return places + " · " + (kinds == 1 ? "1 kind of registration" : "\(kinds) kinds of registration")
    }

    private func line(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Palette.inkSecondary)
            Text(value).monospacedDigit().foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.brimFacts)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("\(label), \(value)")
    }
}
