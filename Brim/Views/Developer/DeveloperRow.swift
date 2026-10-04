import AppKit
import BrimCore
import BrimUI
import SwiftUI

extension DeveloperCache {
    /// "Xcode derived data": the tool and the cache, as a person says it.
    var title: String {
        "\(tool) \(name.lowercased())"
    }

    var qualifiedSize: String {
        if cacheSizeIsPending {
            return sizeDescription
        }
        return sizeDescription + " estimated"
    }

    private var cacheSizeIsPending: Bool {
        sizeMeasurement?.state == .pending || sizeMeasurement?.state == .unknown
    }

    /// What clearing it costs, in a few words.
    var consequence: String {
        if cost == .configured {
            return "Holds your setup"
        }
        if cost == .restored, isProject {
            return "To the Trash, restore dependencies before building"
        }
        if cost == .refetched, manualCleanupReason != nil {
            return "Review with \(tool)"
        }
        if let lastBuilt {
            return Self.built(lastBuilt)
        }
        // Two copies of one update are told apart by their file.
        if isUpdateDownload {
            return url.lastPathComponent
        }
        if let versionInUse {
            return "Not used · runs \(versionInUse)"
        }
        return switch cost {
        case .rebuilt: "Costs one slow build"
        case .refetched: "Downloaded again when needed"
        case .restored: "To the Trash, restore dependencies before building"
        case .configured: "Holds your setup"
        }
    }

    /// "Built today", "Built 11 days ago": whether you are still working
    /// on it is the whole question for a project's build output.
    static func built(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Built today"
        }
        if calendar.isDateInYesterday(date) {
            return "Built yesterday"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days < 60 {
            return "Built \(days) days ago"
        }
        return "Built \(days / 30) months ago"
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
                GroupRule(id: "projects", title: "Project builds", matches: \.isProject,
                          order: { $0.sizeBytes > $1.sizeBytes }),
                GroupRule(id: "updates", title: "Update downloads", matches: \.isUpdateDownload,
                          order: { $0.sizeBytes > $1.sizeBytes }),
                GroupRule(id: "versions", title: "Old versions", matches: \.isOldVersion,
                          order: { $0.sizeBytes > $1.sizeBytes }),
                GroupRule(id: "rebuilt", title: "Rebuilds by itself", matches: { $0.cost == .rebuilt }, order: order),
                GroupRule(id: "restored", title: "Restore before building",
                          matches: { $0.cost == .restored }, order: order),
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

    static func source(_ item: DeveloperCache) -> IconSource {
        if let app = item.app {
            return .bundle(app)
        }
        return source(item.tool)
    }

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
                Toggle("Select \(cache.title)", isOn: Binding(get: { isPicked }, set: { wanted in
                    if wanted != isPicked {
                        pick()
                    }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(isPicked ? "Remove from Tray" : "Add to Tray")
            }
            BrimIcon(
                source: ToolIcon.source(cache),
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
            .accessibilityLabel("\(cache.title), \(cache.consequence), \(cache.sizeDescription)")
            .accessibilityAction { inspect() }
            Spacer(minLength: 8)
            HoverActions {
                RowAction(symbol: "arrow.up.forward.app", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([cache.url])
                }
            }
            Text(cache.sizeDescription)
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight(compact: compact))
        .rowHighlight(isInspected: isInspected, action: inspect)
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
    var canCleanUp = true

    @SwiftUI.Environment(ShellState.self) private var shell

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BrimIcon(source: ToolIcon.source(cache), size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(cache.title)
                        .font(.brimPageTitle)
                        .foregroundStyle(Palette.ink)
                    Text(cache.qualifiedSize)
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
                if let gap = cache.sizeMeasurement?.completeness.explanation {
                    Label(gap, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Palette.caution)
                }
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
        case .restored: "arrow.uturn.backward"
        case .configured: "hand.raised"
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch cache.cost {
        case .rebuilt, .restored:
            Button(isPicked ? "Remove from Tray" : "Add to Tray", action: pick)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        case .refetched:
            // The exact command, shown before anything is approved:
            // delegating is not a silent handoff (T-5.7).
            if cache.cleanupID == "homebrew.cleanup" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Completed downloads can be moved to the Trash. Files still downloading stay.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkSecondary)
                    Button("Clean Up Downloads", action: cleanUp)
                        .disabled(!canCleanUp)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            } else if cache.cleanupID == "uv.cache" {
                Text("Automatic cleanup is unavailable because uv can remove environments or break linked packages. Manage this cache in uv after reviewing the environments that use it.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else if let command = cache.cleanupCommand {
                VStack(alignment: .leading, spacing: 8) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.well, in: .rect(cornerRadius: 8))
                    if let reason = cache.manualCleanupReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Palette.inkSecondary)
                    } else if cache.cleanupID != nil {
                        Button("Clean Up with \(cache.tool)", action: cleanUp)
                            .disabled(!canCleanUp)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                    }
                }
            } else if let reason = cache.manualCleanupReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
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
