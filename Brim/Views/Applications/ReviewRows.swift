import BrimCore
import SwiftUI

/// Consecutive steps in one folder, shown as one row once there are more
/// than five of them.
struct ReviewRun: Identifiable {
    let folder: String
    let steps: [Step]
    var id: Int {
        steps[0].index
    }

    static func runs(of steps: [Step]) -> [ReviewRun] {
        let byFolder = Dictionary(grouping: steps) { ($0.target as NSString).deletingLastPathComponent }
        return steps.reduce(into: [ReviewRun]()) { runs, step in
            let folder = (step.target as NSString).deletingLastPathComponent
            let siblings = byFolder[folder] ?? []
            if siblings.count > 5 {
                guard !runs.contains(where: { $0.folder == folder && $0.steps.count > 1 }) else { return }
                runs.append(ReviewRun(folder: folder, steps: siblings))
            } else {
                runs.append(ReviewRun(folder: folder, steps: [step]))
            }
        }
    }
}

/// A section's title as its first row. A pinned header draws its own band
/// and rule over the rows beneath it, and regions here are told apart by
/// space and type, never by lines.
struct ReviewHeading: View {
    let title: String
    var count: Int?
    var bytes: Int64?
    var isFirst = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.brimGroupTitle)
                .foregroundStyle(Palette.ink)
            if let count {
                Text([count.formatted(), bytes.map { ByteText.short($0) }].compactMap(\.self)
                    .joined(separator: " · "))
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        // Space is what separates one group from the next.
        .padding(.top, isFirst ? 2 : 16)
        .padding(.bottom, 2)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
