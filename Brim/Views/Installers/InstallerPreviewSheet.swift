import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// What an installer would put on this Mac, before it is run.
///
/// Opened by dropping a package, disk image or app that is not installed on
/// the window or the Dock icon, from Home, or from File › Look Inside an
/// Installer. Nothing is installed: a package is read from its own file
/// list, a disk image is mounted hidden and read-only and then ejected.
struct InstallerPreviewSheet: View {
    let request: InstallerRequest
    @ObservedObject var recording: InstallRecordingModel
    @SwiftUI.Environment(\.brimService) private var service
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(ShellState.self) private var shell
    @State private var phase: Phase = .reading

    enum Phase {
        case reading
        case read(InstallerPreview)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            footer
        }
        // Fixed, so the list's measurement never feeds the window's
        // (`CLAUDE.md`, on scrolling sheets).
        .frame(width: 620, height: 660)
        .task(id: request.id) { await read() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .reading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading \(request.url.lastPathComponent)")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 520)
            .accessibilityElement(children: .combine)
        case let .failed(message):
            EmptyState(symbol: "shippingbox", title: "Could not look inside", message: message)
                .frame(minHeight: 520)
        case let .read(preview):
            VStack(alignment: .leading, spacing: 24) {
                InstallerHeader(preview: preview)
                if preview.kind == .diskImage {
                    ForEach(preview.contents) { inner in
                        VStack(alignment: .leading, spacing: 16) {
                            InstallerHeader(preview: inner, compact: true)
                            InstallerDetails(preview: inner)
                        }
                        .padding(16)
                        .card(radius: Metrics.cardRadius - 4)
                    }
                    InstallerLimits(limits: preview.limits)
                } else {
                    InstallerDetails(preview: preview)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Show in Finder") { shell.showInFinder(request.url) }
                .capsuleAction()
            Spacer()
            // Looking inside says what an installer can do; recording says
            // what it did. Offered once there is something to install.
            if case .read = phase, !recording.isRecording {
                Button("Record Its Install") {
                    Task {
                        await recording.start(service: service)
                        if recording.isRecording {
                            dismiss()
                        }
                    }
                }
                .capsuleAction()
                .help("Notes what is on this Mac now, so Brim can show what installing this adds")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .capsuleAction(prominent: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func read() async {
        phase = .reading
        do {
            phase = try await .read(service.previewInstaller(at: request.url))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// The installer's name, what kind of file it is, and who signed it.
struct InstallerHeader: View {
    let preview: InstallerPreview
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            icon
                .frame(width: compact ? 44 : 52, height: compact ? 44 : 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.name)
                    .font(compact ? .brimGroupTitle : .brimPageTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(facts)
                        .foregroundStyle(Palette.inkSecondary)
                    InstallerVerdict(signature: preview.signature)
                }
                .font(.brimFacts)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        if let data = preview.apps.first?.icon, preview.kind == .application, let image = NSImage(data: data) {
            Image(nsImage: image).resizable()
        } else {
            BrimIcon(source: .finder(preview.source), size: compact ? 44 : 52)
        }
    }

    private var facts: String {
        var parts: [String] = []
        switch preview.kind {
        case .package: parts.append("Installer package")
        case .diskImage: parts.append("Disk image")
        case .application: parts.append(preview.apps.first?.version.map { "App, version \($0)" } ?? "App")
        }
        if let total = preview.totalBytes, total > 0 {
            parts.append("Up to \(ByteText.short(total))")
        }
        if let developer = preview.signature.developer {
            parts.append(developer)
        }
        return parts.joined(separator: " · ")
    }
}

/// Gatekeeper's verdict, as a word with a symbol. Status colour only where
/// the verdict is a status: notarized, or not.
struct InstallerVerdict: View {
    let signature: InstallerSignature

    var body: some View {
        switch signature.verdict {
        case .notarized:
            mark("Notarized", "checkmark.seal.fill", Palette.success)
        case .apple:
            mark("From Apple", "checkmark.seal.fill", Palette.success)
        case .appStore:
            mark("From the App Store", "checkmark.seal.fill", Palette.success)
        case .notNotarized:
            mark("Not notarized", "exclamationmark.triangle.fill", Palette.caution)
        case .unsigned:
            mark("Unsigned", "exclamationmark.triangle.fill", Palette.caution)
        case .unknown:
            Text("Gatekeeper could not check it")
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    private func mark(_ word: String, _ symbol: String, _ colour: Color) -> some View {
        Label {
            Text(word).foregroundStyle(Palette.inkSecondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(colour)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// What the reading could not see, quietly, at the end.
struct InstallerLimits: View {
    let limits: [String]

    var body: some View {
        if !limits.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(limits, id: \.self) { limit in
                    Text(limit)
                }
            }
            .font(.caption)
            .foregroundStyle(Palette.inkTertiary)
        }
    }
}
