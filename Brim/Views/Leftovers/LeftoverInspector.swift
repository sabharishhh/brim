import BrimCore
import BrimUI
import SwiftUI
import TipKit

/// Everything about one owner: who it is, how Brim knows, what stops it,
/// and every place it lives.
///
/// A `List`, not a `ScrollView` over a `VStack`: a list measures a row once
/// and reuses it, where a stack re-measures every line of text on every
/// pass, which profiling found costing half the main thread here.
struct LeftoverInspector: View {
    let group: LeftoverGroup
    let isPicked: Bool
    let isKept: Bool
    let pick: () -> Void
    let keep: () -> Void

    /// Built once. A `RelativeDateTimeFormatter` is expensive to construct.
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        List {
            Group {
                header
                if let obstacle = group.sharedObstacle, let why = RemovalCapability.explanation(obstacle) {
                    blocked(why)
                }
                actions
                Text("Where it is")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, 8)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            .listRowBackground(Color.clear)

            ForEach(group.items) { item in
                LocationRow(item: item, showsObstacle: group.sharedObstacle == nil)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrimIcon(source: group.ownerIcon, size: 64, badge: isKept ? .kept : nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                if let identifier = group.identifier {
                    Text(identifier)
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            HStack(spacing: 12) {
                Text(ByteText.short(group.totalBytes))
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
                if let accessed = group.lastAccessed {
                    Text("Used " + Self.relative.localizedString(for: accessed, relativeTo: .now))
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            Text(group.evidence)
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(isPicked ? "Remove from Tray" : "Add to Tray", action: pick)
                .buttonStyle(.borderedProminent)
                .disabled(!group.isFullyActionable || isKept)
            Button(isKept ? "Stop Keeping" : "Keep", action: keep)
                .buttonStyle(.bordered)
                .popoverTip(KeepTip(), arrowEdge: .top)
        }
        .buttonBorderShape(.capsule)
    }

    /// What stops Brim, and the one way past it: Finder, with every file
    /// already selected.
    private func blocked(_ why: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(Palette.caution)
            VStack(alignment: .leading, spacing: 6) {
                Text("Brim cannot remove this")
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(why)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(group.items.count == 1 ? "Show in Finder" : "Show All in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(group.items.map(\.url))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.caution.opacity(0.08), in: .rect(cornerRadius: Metrics.rowRadius))
    }
}

/// One location: Finder's icon, what it is, what removing it costs, where.
private struct LocationRow: View {
    let item: Leftover
    /// False when the card above already says what stops the whole group.
    let showsObstacle: Bool

    @SwiftUI.Environment(ShellState.self) private var shell

    var body: some View {
        let domain = LeftoverDomain.of(item.url)
        HStack(alignment: .top, spacing: 10) {
            BrimIcon(source: .finder(item.url), size: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(domain.title)
                        .font(.brimRowTitle)
                        .foregroundStyle(Palette.ink)
                    Text(domain.isRegenerated ? "Rebuilds" : "Data")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(domain.isRegenerated ? Palette.inkSecondary : Palette.caution)
                    Spacer()
                    Text(ByteText.short(item.size))
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                }
                Text(Self.abbreviated(item.url.path))
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsObstacle, !item.canBeRemovedByBrim, let why = RemovalCapability.explanation(item.capability) {
                    Label(why, systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(Palette.caution)
                }
            }
            HoverActions {
                RowAction(symbol: "arrow.up.forward.app", help: "Reveal in Finder") {
                    shell.reveal([item.url])
                }
            }
        }
        .padding(10)
        .rowHighlight(isInspected: false)
        .contentShape(.rect)
        // Double-click shows it in Finder: a folder opens, a file is
        // selected in its folder.
        .onTapGesture(count: 2) { shell.showInFinder(item.url) }
        .contextMenu { ItemMenuItems(urls: [item.url]) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("\(domain.title), \(domain.consequence), \(ByteText.short(item.size))")
        .accessibilityValue(item.url.path)
        .accessibilityAction(named: "Show in Finder") { shell.showInFinder(item.url) }
    }

    /// The home folder as `~`, which is how people read their own paths.
    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
