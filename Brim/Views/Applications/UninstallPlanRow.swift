import BrimCore
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
        HStack(alignment: .top, spacing: 10) {
            if let selection {
                Toggle("Include \(target)", isOn: selection)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityHint("\(title), \(ByteText.short(bytes))")
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout)
                    if tier == .C {
                        Text("Name match")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteText.short(bytes))
                        .font(.callout)
                        .monospacedDigit()
                    Button("Details", systemImage: "info.circle") {
                        showsDetails = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Details for \(target)")
                    .popover(isPresented: $showsDetails) {
                        Text(evidence)
                            .font(.callout)
                            .padding()
                            .frame(width: 320, alignment: .leading)
                    }
                }
                HStack(spacing: 6) {
                    Text(Self.abbreviated(count > 1 ? target : (target as NSString).deletingLastPathComponent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .help(target)

                    if let action {
                        Text(action)
                            .font(.caption2)
                            .foregroundStyle(disposition == .delete ? .orange : .secondary)
                    }
                }
            }
        }
        .padding(.vertical, 1)
        // Regions are told apart by space and headings, never by rules.
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .contain)
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
        case .archivePath: return "Archive"
        // Root's items go to the helper's holding folder, not the Trash.
        case .trashPathPrivileged: return "Set aside"
        default:
            guard let disposition else { return nil }
            return disposition == .delete ? "Delete permanently" : "To Trash"
        }
    }
}
