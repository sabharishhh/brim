import SwiftUI
import BrimCore

/// The evidence stays visible both before and after a person includes a row.
struct UninstallPlanRow: View {
    let target: String
    let evidence: String
    let bytes: Int64
    let disposition: StepDisposition?
    let kind: StepKind?
    let tier: EvidenceTier?
    var selection: Binding<Bool>?

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
                    Text(target)
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
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch kind {
        case .clearImmutableFlag: return "Locked file"
        case .forgetReceipt: return "Installer record"
        case .revealVendorUninstaller: return "Vendor uninstaller"
        default: break
        }
        let url = URL(fileURLWithPath: target)
        if url.pathExtension == "app" { return "Application" }
        if url.pathExtension == "sfl4" { return "Recent documents list" }
        let domain = LeftoverDomain.of(url)
        return domain == .other ? url.lastPathComponent : domain.title
    }

    private var action: String? {
        switch kind {
        case .clearImmutableFlag: return "Unlock"
        case .forgetReceipt: return "Remove record"
        case .revealVendorUninstaller: return "Show in Finder"
        case .archivePath: return "Archive"
        default:
            guard let disposition else { return nil }
            return disposition == .delete ? "Delete permanently" : "To Trash"
        }
    }
}
