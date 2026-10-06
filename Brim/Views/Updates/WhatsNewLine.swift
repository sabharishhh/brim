import BrimUI
import SwiftUI

/// What an update changes: a placeholder while the on-device model reads
/// the notes, then up to three highlights, with the Security fix tag
/// first when there is one. Generated text carries the Apple Intelligence
/// mark; notes short enough to show as written do not.
struct WhatsNewLine: View {
    let state: WhatsNewModel.State
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            switch state {
            case .reading:
                SkeletonBar(width: 180, height: 8)
                    .shimmer()
                    .appearsAfterBriefWait()
                    .transition(.opacity)
            case let .ready(news):
                HStack(spacing: 6) {
                    if news.fixesSecurity {
                        Label("Security fix", systemImage: "lock.shield.fill")
                            .foregroundStyle(Palette.info)
                    }
                    if news.isGenerated, !news.highlights.isEmpty {
                        Image(systemName: "apple.intelligence")
                            .foregroundStyle(Palette.inkTertiary)
                    }
                    Text(news.highlights.joined(separator: " · "))
                        .foregroundStyle(Palette.inkSecondary)
                        .truncationMode(.tail)
                }
                .help(news.highlights.joined(separator: "\n"))
                .transition(.opacity)
            }
        }
        .font(.brimFacts)
        .frame(height: 16, alignment: .leading)
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: state)
    }

    /// What VoiceOver adds to the row.
    static func spoken(_ state: WhatsNewModel.State) -> String {
        guard case let .ready(news) = state else { return "" }
        let security = news.fixesSecurity ? ", security fix" : ""
        guard !news.highlights.isEmpty else { return security }
        let source = news.isGenerated ? ", what's new, summarised by Apple Intelligence: " : ", what's new: "
        return security + source + news.highlights.joined(separator: ", ")
    }
}
