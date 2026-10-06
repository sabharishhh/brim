import BrimCore
import BrimUI
import SwiftUI

// swiftformat:disable wrapMultilineStatementBraces

/// One application's registrations in depth: who signed them, what state
/// they are in, and each record with the evidence for it.
///
/// A `List`, like the Leftovers inspector, so each record is measured once.
struct BackgroundInspector: View {
    let entry: BackgroundEntry
    let icon: IconSource
    let canPick: Bool
    let isPicked: Bool
    /// Brim's helper is set up and can take the jobs that need it.
    let helperIsReady: Bool
    let pick: () -> Void
    @SwiftUI.Environment(\.backgroundReveals) private var reveals

    var body: some View {
        List {
            Group {
                header
                switch entry.state {
                case .gone:
                    Label("App not found", systemImage: "exclamationmark.triangle")
                        .font(.brimFacts)
                        .foregroundStyle(Palette.caution)
                case .clearing:
                    Label("Still listed by macOS", systemImage: "clock")
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                case .present:
                    EmptyView()
                }
                actions
                Text(entry.group.items.count == 1 ? "Record" : "Records")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, 8)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            .listRowBackground(Color.clear)

            ForEach(entry.group.items) { item in
                RecordRow(registration: item, helperIsReady: helperIsReady)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                    .listRowBackground(Color.clear)
            }
            ListBottomSpacing()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrimIcon(source: icon, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.group.displayName)
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                Text(entry.group.id)
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 12) {
                Text(entry.facts)
                Label(entry.group.signerDescription, systemImage: "checkmark.seal")
                    .labelStyle(.titleAndIcon)
            }
            .font(.brimFacts)
            .foregroundStyle(Palette.inkSecondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        let urls = Array(Set(entry.group.items.compactMap { reveals[$0.id] })).sorted { $0.path < $1.path }
        if entry.state == .gone || !urls.isEmpty {
            HStack(spacing: 8) {
                if entry.state == .gone {
                    Button(isPicked ? "Remove from Tray" : "Add to Tray", action: pick)
                        .capsuleAction(prominent: true)
                        .disabled(!canPick)
                }
                if !urls.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(urls)
                    }
                    .capsuleAction()
                }
            }
            .buttonBorderShape(.capsule)
        }
        if entry.group.items.contains(where: { $0.isStale && $0.loginItemsFollowUp != nil }),
           let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            Link("Open Login Items", destination: url)
                .capsuleAction()
        }
    }
}

/// One record: its kind, what it is called, where it is, and how Brim knows.
private struct RecordRow: View {
    let registration: Registration
    let helperIsReady: Bool

    @SwiftUI.Environment(ShellState.self) private var shell
    @SwiftUI.Environment(\.backgroundReveals) private var reveals

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: registration.itemKind.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 20, height: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(registration.label)
                        .font(.brimRowTitle)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(registration.kind.displayName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Palette.inkSecondary)
                    Spacer(minLength: 0)
                }
                if let location = registration.spokenLocation {
                    Text(registration.kind == .backgroundItem
                        ? "Target: " + Self.abbreviated(location) : Self.abbreviated(location))
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if registration.kind == .backgroundItem, let source = registration.recordPath {
                    Label("Shared macOS store: " + URL(fileURLWithPath: source).lastPathComponent,
                          systemImage: "externaldrive")
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(source)
                }
                Text(registration.evidence)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let signing = registration.signing, signing.isTrouble {
                    Label(signing.shortDescription, systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(Palette.caution)
                }
                if let blocked {
                    Label(blocked, systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let url = reveals[registration.id] {
                HoverActions {
                    RowAction(symbol: "arrow.up.forward.app", help: "Show Target in Finder") {
                        shell.reveal([url])
                    }
                }
            }
        }
        .padding(10)
        .rowHighlight(isInspected: false)
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            if let url = reveals[registration.id] {
                shell.showInFinder(url)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(registration.spokenDescription)
        .accessibilityValue(registration.spokenLocation ?? "")
    }

    /// Why Brim cannot remove this, said before it is tried. Once the
    /// helper can reach it, it stops saying so.
    private var blocked: String? {
        if registration.isStale, let followUp = registration.loginItemsFollowUp {
            return followUp.sentence
        }
        if registration.kind == .backgroundItem {
            return registration.isStale
                ? "The target is missing, but macOS still keeps this record. Turning it off does not remove it."
                : nil
        }
        if registration.kind == .appExtension || registration.kind == .systemExtension {
            return "Review this extension in System Settings > General > Login Items & Extensions."
        }
        if registration.kind == .firewallEntry {
            return "Review this entry in System Settings > Network > Firewall > Options."
        }
        if registration.kind == .privacyGrant {
            return "Remove it in System Settings > Privacy & Security: select it and click the minus button."
        }
        guard registration.isActionableStale else { return nil }
        if helperIsReady, BackgroundModel.needsTheHelper(registration) {
            return nil
        }
        return RemovalCapability.explanation(registration.capability)
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
