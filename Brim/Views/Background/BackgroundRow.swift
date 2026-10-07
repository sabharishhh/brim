import BrimCore
import BrimUI
import SwiftUI

extension Registration {
    /// The kind of thing this is, for its symbol (plan §9).
    var itemKind: ItemKind {
        switch kind {
        case .backgroundItem: launchesAtLogin ? .loginItem : .backgroundItem
        case .launchdJob: recordPath?.contains("/LaunchDaemons/") == true ? .launchDaemon : .launchAgent
        case .privilegedHelper: .launchDaemon
        case .legacyLoginItem: .loginItem
        case .firewallEntry, .privacyGrant, .keychainItem, .configurationProfile: .privacyPermission
        case .launchServices: .launchServicesRecord
        case .appExtension, .bundlePlugin: .appExtension
        case .systemExtension: .systemExtension
        case .installerReceipt, .shellProfileLine: .file
        }
    }

    /// An individual declaration or target, never a shared macOS store.
    var revealableURL: URL? {
        revealCandidatePaths.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

extension EnvironmentValues {
    /// Each record's file to show in Finder, by registration id. Worked out
    /// once per scan: finding it asks the disk, and rows ask while drawing.
    @Entry var backgroundReveals: [String: URL] = [:]
}

extension BackgroundEntry {
    /// The application's icon while it is installed, the saved one once it
    /// is gone, otherwise a symbol for the kind of registration. Reads the
    /// disk, so it is worked out once per scan and not while drawing.
    var icon: IconSource {
        let first = group.items.first
        return IconResolver.source(
            for: IconSubject(
                name: group.displayName, kind: first?.itemKind ?? .backgroundItem,
                ownerName: group.displayName, ownerBundleID: first?.owningBundleID,
                ownerURL: group.items.lazy.compactMap(\.enclosingApplication).first
            ),
            remembered: { IconMemory.standard.has($0) }
        )
    }

    private var loneExtension: Registration? {
        guard group.items.count == 1, let only = group.items.first, only.kind == .appExtension else { return nil }
        return only.label.isEmpty || only.label == group.displayName ? nil : only
    }

    /// "Background job, login item", capitalised.
    var facts: String {
        // A lone extension names itself: WhatsApp has two, and two rows of
        // "WhatsApp, App extension" could not be told apart.
        if let only = loneExtension {
            return "App extension · \(only.label)"
        }
        let text = group.composition
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// One application on the Background page: tick where there is something
/// to remove, icon, name, what it registered.
struct BackgroundRow: View {
    let entry: BackgroundEntry
    let icon: IconSource
    let canPick: Bool
    let isPicked: Bool
    let needsHelper: Bool
    let isInspected: Bool
    let pick: () -> Void
    let inspect: () -> Void
    @SwiftUI.Environment(\.backgroundReveals) private var reveals
    /// Denser rows, from View ▸ Compact Rows.
    @SwiftUI.Environment(\.compactRows) private var compact

    var body: some View {
        HStack(spacing: 12) {
            if entry.state == .gone {
                Toggle(
                    "Select \(entry.group.displayName)",
                    isOn: Binding(get: { isPicked }, set: { wanted in
                        if wanted != isPicked {
                            pick()
                        }
                    })
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canPick)
                .help(canPick ? (isPicked ? "Remove from Tray" : "Add to Tray") : "Brim cannot remove this")
            }
            BrimIcon(source: icon, size: Metrics.rowIcon(compact: compact), badge: badge)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.group.displayName)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                if !compact {
                    Text(entry.facts)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(isInspected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel("\(entry.group.displayName), \(entry.facts)")
            .accessibilityAction { inspect() }
            Spacer(minLength: 8)
            if let url = entry.group.items.lazy.compactMap({ reveals[$0.id] }).first {
                HoverActions {
                    RowAction(symbol: "arrow.up.forward.app", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight(compact: compact))
        .rowHighlight(isInspected: isInspected, action: inspect)
    }

    private var badge: IconBadge? {
        if needsHelper {
            return .helper
        }
        if entry.state != .present {
            return .removed
        }
        if case .bundle = icon, entry.runsInBackground {
            return .job
        }
        return nil
    }
}
