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
        case .privacyGrant, .keychainItem: .privacyPermission
        case .launchServices: .launchServicesRecord
        case .appExtension, .bundlePlugin: .appExtension
        case .systemExtension: .systemExtension
        case .installerReceipt, .shellProfileLine: .file
        }
    }

    /// The application this runs, when its program sits inside one.
    var enclosingApplication: URL? {
        guard let programPath else { return nil }
        var url = URL(fileURLWithPath: programPath)
        while url.path != "/" {
            if url.pathExtension == "app" {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// The file to show in Finder: the record itself, or failing that what
    /// it runs, whichever is still there.
    var revealableURL: URL? {
        [recordPath, programPath].compactMap(\.self).map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
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

    /// "Background job, login item", capitalised.
    var facts: String {
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
    /// Denser rows, from View ▸ Compact Rows.
    @SwiftUI.Environment(\.compactRows) private var compact

    var body: some View {
        HStack(spacing: 12) {
            if entry.state == .gone {
                Toggle("Select \(entry.group.displayName)", isOn: Binding(get: { isPicked }, set: { _ in pick() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!canPick)
                    .help(canPick ? (isPicked ? "Remove from Tray" : "Add to Tray") : "Needs Brim's helper")
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
            if let url = entry.group.items.lazy.compactMap(\.revealableURL).first {
                HoverActions {
                    RowAction(symbol: "arrow.up.forward.app", help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight(compact: compact))
        .rowHighlight(isInspected: isInspected)
        .onTapGesture(perform: inspect)
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
