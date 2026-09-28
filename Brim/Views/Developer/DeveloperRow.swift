import AppKit
import BrimCore
import BrimUI
import SwiftUI

extension DeveloperCache {
    /// "Xcode derived data": the tool and the cache, as a person says it.
    var title: String {
        "\(tool) \(name.lowercased())"
    }

    /// What clearing it costs, in a few words.
    var consequence: String {
        switch cost {
        case .rebuilt: "Costs one slow build"
        case .refetched: "Downloaded again when needed"
        case .configured: "Holds your setup"
        }
    }

    /// The developer's groups (plan §8), by what clearing each costs.
    static func sections(_ caches: [DeveloperCache]) -> [ItemGroup<DeveloperCache>] {
        let order: (DeveloperCache, DeveloperCache) -> Bool = {
            $0.tool == $1.tool ? $0.sizeBytes > $1.sizeBytes
                : $0.tool.localizedStandardCompare($1.tool) == .orderedAscending
        }
        return Grouping.assign(
            caches,
            rules: [
                GroupRule(id: "rebuilt", title: "Rebuilds by itself", matches: { $0.cost == .rebuilt }, order: order),
                GroupRule(id: "tool", title: "Managed by its tool", matches: { $0.cost == .refetched }, order: order)
            ],
            otherwise: GroupRule(id: "yours", title: "Left to you", matches: { _ in true }, order: order)
        )
    }
}

/// Icons for the tools, found once. An app's icon where the tool is an
/// app, otherwise its monogram.
@MainActor
enum ToolIcon {
    private static let applications = [
        "Xcode": "com.apple.dt.Xcode",
        "Docker": "com.docker.docker"
    ]
    private static var cache: [String: IconSource] = [:]

    static func source(_ tool: String) -> IconSource {
        if let known = cache[tool] {
            return known
        }
        let url = applications[tool].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let source: IconSource = url.map { .bundle($0) } ?? .monogram(Monogram(name: tool))
        cache[tool] = source
        return source
    }
}

/// One cache: tick where Brim can clear it, the tool's icon, what it is,
/// what clearing it costs, its size.
struct DeveloperRow: View {
    let cache: DeveloperCache
    let isPicked: Bool
    let isInspected: Bool
    let pick: () -> Void
    let inspect: () -> Void
    /// Denser rows, from View ▸ Compact Rows.
    @SwiftUI.Environment(\.compactRows) private var compact

    var body: some View {
        HStack(spacing: 12) {
            if cache.cost.isBrimRemovable {
                Toggle("Select \(cache.title)", isOn: Binding(get: { isPicked }, set: { _ in pick() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(isPicked ? "Remove from Tray" : "Add to Tray")
            }
            BrimIcon(
                source: ToolIcon.source(cache.tool),
                size: Metrics.rowIcon(compact: compact),
                badge: cache.cost == .rebuilt ? .regenerates : nil
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(cache.title)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                if !compact {
                    Text(cache.consequence)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(isInspected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel("\(cache.title), \(cache.consequence), \(ByteText.short(cache.sizeBytes))")
            .accessibilityAction { inspect() }
            Spacer(minLength: 8)
            HoverActions {
                RowAction(symbol: "arrow.up.forward.app", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([cache.url])
                }
            }
            Text(ByteText.short(cache.sizeBytes))
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight(compact: compact))
        .rowHighlight(isInspected: isInspected)
        .onTapGesture(perform: inspect)
    }
}

/// One cache in depth: what it is, what clearing it costs, and the one
/// thing to do about it, which depends on its class.
struct DeveloperInspector: View {
    let cache: DeveloperCache
    let isPicked: Bool
    let pick: () -> Void
    /// Plans the tool's own command, for the review.
    let cleanUp: () -> Void

    @SwiftUI.Environment(ShellState.self) private var shell

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BrimIcon(source: ToolIcon.source(cache.tool), size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(cache.title)
                        .font(.brimPageTitle)
                        .foregroundStyle(Palette.ink)
                    Text(ByteText.short(cache.sizeBytes))
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                }
                Label(cache.consequence, systemImage: symbol)
                    .font(.brimFacts)
                    .foregroundStyle(cache.cost == .configured ? Palette.caution : Palette.inkSecondary)
                Text(cache.explanation)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
                location
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var symbol: String {
        switch cache.cost {
        case .rebuilt: "arrow.triangle.2.circlepath"
        case .refetched: "icloud.and.arrow.down"
        case .configured: "hand.raised"
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch cache.cost {
        case .rebuilt:
            Button(isPicked ? "Remove from Tray" : "Add to Tray", action: pick)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
        case .refetched:
            // The exact command, shown before anything is approved:
            // delegating is not a silent handoff (T-5.7).
            if cache.cleanupID != nil, let command = cache.cleanupCommand {
                VStack(alignment: .leading, spacing: 8) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.well, in: .rect(cornerRadius: 8))
                    Button("Clean Up with \(cache.tool)", action: cleanUp)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                }
            }
        case .configured:
            EmptyView()
        }
    }

    private var location: some View {
        HStack(alignment: .top, spacing: 10) {
            BrimIcon(source: .finder(cache.url), size: 20)
            Text(Self.abbreviated(cache.url.path))
                .font(.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            RowAction(symbol: "arrow.up.forward.app", help: "Reveal in Finder") { shell.reveal([cache.url]) }
        }
        .padding(8)
        .background(Palette.well, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onTapGesture(count: 2) { shell.showInFinder(cache.url) }
        .accessibilityElement(children: .combine)
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
