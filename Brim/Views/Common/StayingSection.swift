import BrimCore
import SwiftUI

/// What only the person can finish, with the reason, shown before approval
/// with a way to it in Finder.
struct StayingSection: View {
    let items: [ExcludedItem]

    var body: some View {
        if !items.isEmpty {
            Section {
                HStack {
                    ReviewHeading(title: "Needs you", count: items.count)
                    Spacer()
                    if items.count > 1 {
                        RevealButton(urls: items.map { URL(fileURLWithPath: $0.target) }, title: "Show All in Finder")
                            .buttonStyle(PointerButtonStyle(.borderless))
                            .font(.caption)
                    }
                }
                ForEach(items, id: \.target) { item in
                    StayingRow(item: item)
                }
            }
            .listSectionSeparator(.hidden)
        }
    }
}

/// One thing a removal leaves, with the reason, and a way to it in Finder.
struct StayingRow: View {
    let item: ExcludedItem

    var body: some View {
        let name = URL(fileURLWithPath: item.target).lastPathComponent
        HStack(alignment: .top, spacing: 10) {
            LocationIcon(url: URL(fileURLWithPath: item.target))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.brimFacts).foregroundStyle(Palette.ink)
                    Text("Stays").font(.caption).foregroundStyle(Palette.caution)
                }
                Text(PathText.abbreviated((item.target as NSString).deletingLastPathComponent))
                    .font(.caption).foregroundStyle(Palette.inkTertiary)
                    .truncationMode(.middle).lineLimit(1)
                Text(item.reason)
                    .font(.caption).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            RevealButton(urls: [URL(fileURLWithPath: item.target)])
                .buttonStyle(PointerButtonStyle(.borderless))
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), stays. \(item.reason)")
        .accessibilityAction(named: "Show in Finder") {
            RevealButton.reveal([URL(fileURLWithPath: item.target)])
        }
        .accessibilityAddTraits(.isStaticText)
    }
}
