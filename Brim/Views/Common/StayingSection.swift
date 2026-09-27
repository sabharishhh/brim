import BrimCore
import SwiftUI

/// What a plan keeps, with the reason, shown before approval.
///
/// Both review sheets need it. Without it, something only an administrator
/// could move was left out of an uninstall plan and the result then said
/// nothing was left.
struct StayingSection: View {
    let items: [ExcludedItem]

    var body: some View {
        if !items.isEmpty {
            Section("Staying (\(items.count))") {
                ForEach(items, id: \.target) { item in
                    let name = URL(fileURLWithPath: item.target).lastPathComponent
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.callout)
                        Text(item.target)
                            .font(.caption).foregroundColor(.secondary)
                            .truncationMode(.middle).lineLimit(1)
                        Text(item.reason)
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(name), staying. \(item.reason)")
                    .accessibilityAddTraits(.isStaticText)
                }
            }
        }
    }
}
