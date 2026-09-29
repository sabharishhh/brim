import BrimCore
import BrimUI
import SwiftUI

/// The evidence stays visible both before and after a person includes a row.
struct UninstallPlanRow: View {
    let target: String
    let evidence: String
    let bytes: Int64
    let disposition: StepDisposition?
    let kind: StepKind?
    let tier: EvidenceTier?
    var selection: Binding<Bool>?
    /// More than one item, shown as one row: the target is then the folder
    /// they share. 682 scratch folders were 682 identical rows.
    var count = 1

    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let selection {
                Toggle("Include \(target)", isOn: selection)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityHint("\(title), \(ByteText.short(bytes))")
            }
            icon

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if tier == .C {
                        Text("Name match")
                            .font(.caption)
                            .foregroundStyle(Palette.inkTertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text(Self.abbreviated(count > 1 ? target : (target as NSString).deletingLastPathComponent))
                        .foregroundStyle(Palette.inkTertiary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .help(target)
                    if let action {
                        Text(action)
                            .foregroundStyle(disposition == .delete ? Palette.caution : Palette.inkSecondary)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 8)
            Text(ByteText.short(bytes))
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
            Button("Details", systemImage: "info.circle") {
                showsDetails = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.inkTertiary)
            .accessibilityLabel("Details for \(target)")
            .popover(isPresented: $showsDetails) {
                Text(evidence)
                    .font(.callout)
                    .padding()
                    .frame(width: 320, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        // Regions are told apart by space and headings, never by rules.
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .contain)
    }

    /// Finder's own icon, so a folder reads as a folder and a file as a
    /// file before anything is read. Every row used to be two lines of text
    /// and nothing to tell them apart at a glance.
    @ViewBuilder
    private var icon: some View {
        let url = URL(fileURLWithPath: target)
        if kind == .forgetReceipt {
            Image(systemName: "shippingbox")
                .font(.system(size: 17))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 26, height: 26)
        } else if count == 1, url.pathExtension == "app" {
            BrimIcon(source: .bundle(url), size: 26)
        } else {
            BrimIcon(source: .finder(url), size: 26)
        }
    }

    /// The item's own name. The group heading already says what kind of
    /// thing it is, and "Cache" under "Cache (1)" said it twice while
    /// leaving out the one thing that told two rows apart.
    private var title: String {
        if count > 1 { return "\(count) items" }
        switch kind {
        case .clearImmutableFlag: return "Locked file"
        case .forgetReceipt: return target
        case .revealVendorUninstaller: return "Vendor uninstaller"
        default: return URL(fileURLWithPath: target).lastPathComponent
        }
    }

    /// Home written as `~`, the way the inspector and Leftovers show it.
    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var action: String? {
        switch kind {
        case .clearImmutableFlag: return "Unlock"
        case .forgetReceipt: return "Remove record"
        case .revealVendorUninstaller: return "Show in Finder"
        // Root's items go to the helper's holding folder, not the Trash.
        case .trashPathPrivileged: return "Set aside"
        default:
            guard let disposition else { return nil }
            return disposition == .delete ? "Delete permanently" : "To Trash"
        }
    }
}
