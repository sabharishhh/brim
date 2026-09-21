import SwiftUI
import UniformTypeIdentifiers
import BrimCore
import BrimProtocol
import BrimUI

/// Files that are byte for byte the same, and what removing the extras
/// would really give back.
///
/// The honest part is the second number. On APFS two identical files often
/// share their blocks already, through a clone or a hard link, so deleting
/// one frees nothing at all. Tools that report the logical total as savings
/// are counting space that was never used twice. Brim reports both and says
/// which groups are in that state.
struct DuplicatesView: View {
    @ObservedObject var model: DuplicatesModel
    @SwiftUI.Environment(\.brimService) private var service

    @State private var reviewRequest: PlanIntent?
    @State private var isChoosingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if model.scannedFolder != nil { Divider(); footer }
        }
        .sheet(item: $reviewRequest) { intent in
            RemovalSheet(
                intent: intent,
                service: service,
                title: "Remove duplicates",
                subtitle: "\(intent.explicitTargets.count) copies of files you are keeping elsewhere"
            ) {
                if let folder = model.scannedFolder {
                    Task { await model.scan(directory: folder, service: service) }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicates").font(.title2).fontWeight(.bold)
                Text(summary).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(model.scannedFolder == nil ? "Choose a folder…" : "Choose another…") {
                chooseFolder()
            }
            .disabled(model.isScanning)
        }
        .padding()
    }

    private var summary: String {
        if model.isScanning { return "Reading the files that share a size…" }
        guard let folder = model.scannedFolder else {
            return "Pick a folder to look through. Brim reads the whole of any file that "
                 + "shares a size with another, so a folder beats a whole disk."
        }
        if model.groups.isEmpty { return "Nothing duplicated in \(folder.lastPathComponent)." }
        return "\(model.groups.count) sets in \(folder.lastPathComponent) · "
             + ByteText.short(model.recoverableBytes) + " would actually come back"
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            VStack(spacing: 8) {
                ProgressView()
                Text("Files of the same size are compared by their ends first, and only the "
                     + "survivors are read in full.")
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            VStack(spacing: 6) {
                Text("The scan did not finish").font(.headline).foregroundColor(.red)
                Text(error).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.scannedFolder == nil {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.doc").font(.largeTitle).foregroundColor(.secondary)
                Text("Choose a folder").font(.headline)
                Text("Brim compares files that share a size, then reads only the ones that "
                     + "still look alike. Nothing is read twice and the scan does not push "
                     + "your own files out of the disk cache.")
                    .foregroundColor(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.groups.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundColor(.green)
                Text("No duplicates").font(.headline)
                Text("Every file in there is one of a kind.").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !model.alreadySharingStorage.isEmpty { sharingNote }
                ForEach(model.groups, id: \.hash) { group in
                    Section {
                        ForEach(group.paths, id: \.self) { path in
                            row(path, in: group)
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var sharingNote: some View {
        Section {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "link").foregroundColor(.secondary)
                Text("\(model.alreadySharingStorage.count) of these sets already share their "
                     + "storage, through an APFS clone or a hard link. The copies are real "
                     + "but the bytes are only stored once, so removing one frees nothing.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
    }

    private func groupHeader(_ group: DuplicateGroup) -> some View {
        HStack {
            Text("\(group.paths.count) copies of "
                 + ByteText.short(group.size)).font(.headline)
            Spacer()
            if group.recoverableBytes == 0 {
                Label("Already sharing storage", systemImage: "link")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text(ByteText.short(group.recoverableBytes) + " to gain")
                    .font(.caption).foregroundColor(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 3)
    }

    private func row(_ path: String, in group: DuplicateGroup) -> some View {
        let isKept = group.paths.first == path
        return HStack(alignment: .top, spacing: 8) {
            // Named for the accessibility tree, hidden visually. Every
            // copy in a set has the same file name, so the label has to
            // carry the path or a reader hears the same thing twice with
            // no way to tell which one is ticked.
            Toggle("Select \(path)", isOn: Binding(
                get: { model.selection.contains(path) },
                set: { _ in model.toggle(path, in: group) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!model.canSelect(path, in: group))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.callout)
                    if isKept {
                        Text("kept").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.18), in: Capsule())
                    }
                }
                Text(path)
                    .font(.caption).foregroundColor(.secondary)
                    .truncationMode(.middle).lineLimit(1).textSelection(.enabled)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(isKept
                ? "\(URL(fileURLWithPath: path).lastPathComponent). The copy this set keeps."
                : URL(fileURLWithPath: path).lastPathComponent)
            .accessibilityValue(path)
        }
        .padding(.vertical, 1)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if model.selection.isEmpty {
                    Text("Nothing picked yet").foregroundColor(.secondary)
                } else {
                    Text("\(model.selection.count) copies · ")
                        .foregroundColor(.secondary)
                    + Text(ByteText.short(model.selectedBytes))
                        .fontWeight(.bold).monospacedDigit()
                }
                Text("Every set keeps its first copy.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Select the extras") { model.selectExtras() }
                .disabled(model.groups.isEmpty)
            Button("None") { model.clearSelection() }
                .disabled(model.selection.isEmpty)
            Button("Review & Remove…") {
                reviewRequest = model.removalIntent(requesterIdentity: NSUserName())
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canRemove)
        }
        .padding()
    }

    /// An open panel, so the folder arrives with the sandbox's permission
    /// rather than Brim reaching wherever it likes.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to look through for duplicates."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.scan(directory: url, service: service) }
    }
}
