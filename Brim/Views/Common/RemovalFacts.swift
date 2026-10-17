import BrimCore
import BrimUI
import SwiftUI

// MARK: - Space

/// Where a plan's bytes go, said the same way in every review.
enum PlanSpace {
    static func phrase(_ plan: Plan) -> String {
        if plan.scanCompleteness?.isComplete == false || plan.steps.contains(where: { $0.sizeIsKnown == false }) {
            return "Size not fully measured"
        }
        let parts = [
            plan.trashedBytes > 0 ? "\(ByteText.short(plan.trashedBytes)) to the Trash" : nil,
            plan.setAsideBytes > 0 ? "\(ByteText.short(plan.setAsideBytes)) set aside" : nil,
            plan.immediatelyFreedBytes > 0 ? "\(ByteText.short(plan.immediatelyFreedBytes)) deleted" : nil
        ].compactMap(\.self)
        // Zero is a real answer: broken links take no space.
        return parts.isEmpty ? "Takes no space" : parts.joined(separator: " · ")
    }

    static func count(_ steps: Int) -> String {
        steps == 1 ? "1 item" : "\(steps.formatted()) items"
    }
}

// MARK: - Sections

/// A titled group of facts on one surface, with hairlines between rows.
struct FactSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.brimFacts.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 12)
            .background(Palette.surface.opacity(0.6), in: .rect(cornerRadius: Metrics.rowRadius))
            .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.well, lineWidth: 0.5))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A label on the left, its figure on the right, and a quieter line under
/// the label when there is more to say.
struct FactRow: View {
    let label: String
    var value: String?
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .font(.brimFacts)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel([label, value, detail].compactMap(\.self).joined(separator: ", "))
    }
}

struct FactDivider: View {
    var body: some View {
        Divider().opacity(0.6)
    }
}
