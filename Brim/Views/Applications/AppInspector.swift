import BrimCore
import BrimUI
import SwiftUI

/// One app in depth: who made it, how it arrived, and everything it has
/// put on this Mac, grouped by what removing it would cost.
///
/// A `List`, not a scroll view over a stack, so each row is measured once.
struct AppInspector: View {
    let app: InstalledApplication
    @ObservedObject var model: ApplicationsModel
    @ObservedObject var access: FullDiskAccessModel
    let opened: String?
    let remove: () -> Void

    private static let installed: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

    /// "Installed 22 Sep · Opened 3 days ago", whichever Brim knows.
    private var dates: String {
        [app.installedAt.map { "Installed " + Self.installed.string(from: $0) }, opened]
            .compactMap(\.self).joined(separator: " · ")
    }

    var body: some View {
        List {
            Group {
                header
                actions
                footprintSummary
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            .listRowBackground(Color.clear)

            if let footprint = model.footprint, !model.isInspecting {
                ForEach(FootprintLoss.arrange(footprint)) { group in
                    Section {
                        ForEach(group.items, id: \.evidence.url) { item in
                            FootprintRow(item: item)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 14))
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                                .font(.brimGroupTitle)
                                .foregroundStyle(Palette.ink)
                            Text("\(group.items.count) · \(ByteText.short(Self.bytes(group)))")
                                .font(.brimFacts)
                                .monospacedDigit()
                                .foregroundStyle(Palette.inkSecondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                    }
                }
            }
            ListBottomSpacing()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    static func bytes(_ group: ItemGroup<FootprintItem>) -> Int64 {
        group.items.reduce(0) { $0 + $1.sizeBytes }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrimIcon(source: .bundle(app.url), size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                Text([app.developer, app.version.map { "Version \($0)" }].compactMap(\.self).joined(separator: " · "))
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            HStack(spacing: 8) {
                if let source = app.source {
                    StatusChip(text: source.title)
                }
                Text(dates)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let reason = model.uninstallBlockedReason {
            Label(reason, systemImage: "lock")
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
        } else {
            Button("Remove", action: remove)
                .buttonStyle(.borderedProminent)
                // Never disabled while the footprint loads: the review works out
                // its own plan, and a disabled button drawn at full strength
                // took a press and did nothing.
                .buttonBorderShape(.capsule)
            // Said before the press: removing it removes the app it ships in.
            if let host = app.enclosingApp {
                Label("Removed with \(host)", systemImage: "shippingbox")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    @ViewBuilder
    private var footprintSummary: some View {
        if model.isInspecting {
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBar(width: 140, height: 24)
                SkeletonBar(width: 260, height: 8)
                SkeletonRows(count: 4, showsTick: false)
            }
            .shimmer()
            .padding(.top, 8)
            .accessibilityLabel("Checking")
        } else if let footprint = model.footprint {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ByteText.short(footprint.totalSizeBytes))
                        .font(.brimFigure)
                        .foregroundStyle(Palette.ink)
                    Text(footprint.items.count == 1 ? "in 1 place" : "in \(footprint.items.count) places")
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
                MeterBar(segments: FootprintLoss.arrange(footprint).prefix(4).enumerated().map { index, group in
                    MeterSegment(
                        label: group.title, value: group.items.reduce(0) { $0 + $1.sizeBytes },
                        color: Palette.hue([1, 5, 2, 0][index])
                    )
                })
                if let gap = footprint.completeness.explanation {
                    Label(gap, systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(Palette.caution)
                }
                if footprint.unreadableEntries > 0 {
                    unreadable(footprint.unreadableEntries)
                }
            }
            .padding(.top, 8)
        }
    }

    /// A total short by an amount Brim could not read says so, and names
    /// the one setting that fixes it when there is one.
    private func unreadable(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Label(
                access.isGranted
                    ? "\(count) protected by macOS, not counted"
                    : "\(count) behind Full Disk Access, not counted",
                systemImage: access.isGranted ? "lock" : "eye.slash"
            )
            .font(.caption)
            .foregroundStyle(Palette.caution)
            if !access.isGranted {
                Button("Open Settings") { FullDiskAccess.openSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

/// One place the app lives: Finder's icon, the path from ~, its size.
private struct FootprintRow: View {
    let item: FootprintItem
    @SwiftUI.Environment(ShellState.self) private var shell

    var body: some View {
        HStack(spacing: 10) {
            BrimIcon(source: .finder(item.evidence.url), size: 24)
            // The name first, then where it sits: two short lines read
            // better than one long path cut in the middle.
            VStack(alignment: .leading, spacing: 1) {
                Text(item.evidence.url.lastPathComponent)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.ink)
                Text(Self.abbreviated(item.evidence.url.deletingLastPathComponent().path))
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            HoverActions {
                RowAction(symbol: "arrow.up.forward.app", help: "Reveal in Finder") {
                    shell.reveal([item.evidence.url])
                }
            }
            Text(ByteText.short(item.sizeBytes))
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .rowHighlight(isInspected: false)
        .contentShape(.rect)
        .onTapGesture(count: 2) { shell.showInFinder(item.evidence.url) }
        .contextMenu { ItemMenuItems(urls: [item.evidence.url]) }
        .help(item.evidence.humanSentence)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("\(item.evidence.url.lastPathComponent), \(ByteText.short(item.sizeBytes))")
        .accessibilityValue(item.evidence.url.path)
        .accessibilityAction(named: "Show in Finder") { shell.showInFinder(item.evidence.url) }
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
