import BrimCore
import BrimUI
import SwiftUI

/// The body of a preview: the apps, then what lands grouped by what it does,
/// then what runs while installing, then what the app may ask for.
struct InstallerDetails: View {
    let preview: InstallerPreview
    @ObservedObject var scriptLines: ScriptLinesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            apps
            ForEach(InstallerPreview.Group.allCases, id: \.self) { group in
                let items = preview.items.filter { $0.group == group }
                if !items.isEmpty {
                    InstallerItemSection(group: group, items: items)
                }
            }
            if !preview.scripts.isEmpty {
                scripts
            }
            facts
            if preview.items.isEmpty, preview.scripts.isEmpty, preview.kind != .diskImage {
                Text(preview.kind == .application ? "Declares nothing that runs on its own" : "Only files")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            if preview.kind != .diskImage {
                InstallerLimits(limits: preview.limits)
            }
        }
    }

    // MARK: - Apps

    @ViewBuilder
    private var apps: some View {
        // An app previewed on its own is the header already; only whether
        // it replaces one here is new.
        if preview.kind == .application, let app = preview.apps.first, let current = app.replacesVersion {
            Label("Replaces version \(current) on this Mac", systemImage: "arrow.triangle.2.circlepath")
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
        } else if preview.kind == .package, !preview.apps.isEmpty {
            InstallerSection(title: "Apps", count: preview.apps.count) {
                ForEach(preview.apps) { app in
                    InstallerRow(
                        symbol: "app.dashed", title: app.version.map { "\(app.name) \($0)" } ?? app.name,
                        detail: app.path, trailing: app.replacesVersion.map { "Replaces \($0)" }
                            ?? (app.isInstalled ? "Replaces the one here" : nil),
                        help: app.identifier
                    )
                }
            }
        }
    }

    // MARK: - Scripts

    private var scripts: some View {
        InstallerSection(title: "Runs while installing", count: preview.scripts.count) {
            ForEach(preview.scripts) { script in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .foregroundStyle(Palette.snow)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(script.name)
                            .font(.brimRowTitle)
                            .foregroundStyle(Palette.ink)
                        if script.runsAsAdministrator {
                            Text("As administrator")
                                .font(.caption)
                                .foregroundStyle(Palette.inkSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Palette.well, in: Capsule())
                        }
                    }
                    if !script.isText || script.findings.isEmpty {
                        Text(script.isText ? "Calls nothing Brim looks for" : "A program, not readable as text")
                            .font(.brimFacts)
                            .foregroundStyle(Palette.inkSecondary)
                            .padding(.leading, 28)
                    } else {
                        ForEach(script.findings.prefix(ScriptLinesModel.shown), id: \.line) { finding in
                            ScriptFindingRow(
                                finding: finding,
                                description: scriptLines.descriptions[script.id]?[finding.line],
                                isReading: scriptLines.reading.contains(script.id)
                            )
                        }
                        let more = script.findings.count - ScriptLinesModel.shown
                        if more > 0 {
                            Text(more == 1 ? "1 more line" : "\(more) more lines")
                                .font(.brimFacts)
                                .foregroundStyle(Palette.inkTertiary)
                                .padding(.leading, 28)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Facts about an app

    @ViewBuilder
    private var facts: some View {
        let rows = factRows
        if !rows.isEmpty {
            InstallerSection(title: "The app", count: nil) {
                ForEach(rows, id: \.title) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.title)
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(width: 140, alignment: .leading)
                        Text(row.value)
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.brimFacts)
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private struct FactRow {
        let title: String
        let value: String
    }

    private var factRows: [FactRow] {
        var rows: [FactRow] = []
        if !preview.permissions.isEmpty {
            rows.append(FactRow(title: "May ask for", value: preview.permissions.joined(separator: ", ")))
        }
        if let sandboxed = preview.isSandboxed {
            rows.append(FactRow(title: "App Sandbox", value: sandboxed ? "Yes" : "No"))
        }
        if let updater = preview.updater {
            rows.append(FactRow(title: "Updates itself", value: "With \(updater)"))
        }
        return rows
    }
}

/// A titled group of rows, at most seven before Show All.
struct InstallerItemSection: View {
    let group: InstallerPreview.Group
    let items: [InstallerPreview.Item]
    @State private var showsAll = false

    var body: some View {
        InstallerSection(title: group.title, count: items.count) {
            ForEach(showsAll ? items : Array(items.prefix(Metrics.rowsBeforeShowAll))) { item in
                InstallerRow(
                    symbol: symbol, title: item.what, detail: item.path,
                    trailing: item.exists ? "Already here" : size(item),
                    help: item.source
                )
            }
            if items.count > Metrics.rowsBeforeShowAll, !showsAll {
                Button("Show All \(items.count)") { showsAll = true }
                    .buttonStyle(.borderless)
                    .font(.brimFacts)
                    .padding(.leading, 28)
            }
            if let source = sharedSource {
                Text(source)
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.leading, 28)
            }
        }
    }

    /// Sizes from a megabyte up. A launch job's few hundred bytes beside
    /// it said nothing.
    private func size(_ item: InstallerPreview.Item) -> String? {
        guard let bytes = item.bytes, bytes >= 1_000_000 else { return nil }
        return ByteText.short(bytes)
    }

    /// One line under the group when every row is known the same way.
    private var sharedSource: String? {
        let sources = Set(items.map(\.source))
        return sources.count == 1 ? sources.first : nil
    }

    private var symbol: String {
        switch group {
        case .background: "gearshape.2"
        case .systemExtensions: "cpu"
        case .commandLine: "terminal"
        case .plugIns: "puzzlepiece.extension"
        case .files: "folder"
        }
    }
}

/// A heading with its count beside it, never under it.
struct InstallerSection<Content: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                if let count {
                    Text("\(count)")
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// One thing: what it is, where it goes, and a size or state at the end.
struct InstallerRow: View {
    let symbol: String
    let title: String
    let detail: String
    let trailing: String?
    let help: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.snow)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(.vertical, 4)
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel([title, detail, trailing].compactMap(\.self).joined(separator: ", "))
    }
}

/// One line of an install script that does something: Brim's words for it,
/// what the on-device model says it does, and the line as written. The
/// model's words sit under Brim's and never replace them, because a script
/// can try to steer what is said about it; the line itself is there to
/// check either against.
private struct ScriptFindingRow: View {
    let finding: InstallScriptReading.Finding
    let description: String?
    let isReading: Bool
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(finding.phrase)
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Text("Line \(finding.line)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkTertiary)
            }
            if description != nil || isReading {
                ZStack(alignment: .leading) {
                    if let description {
                        HStack(spacing: 5) {
                            Image(systemName: "apple.intelligence")
                                .foregroundStyle(Palette.inkTertiary)
                            Text(description)
                                .foregroundStyle(Palette.inkSecondary)
                        }
                        .transition(.opacity)
                    } else {
                        SkeletonBar(width: 160, height: 7)
                            .shimmer()
                            .appearsAfterBriefWait()
                            .transition(.opacity)
                    }
                }
                .frame(height: 16, alignment: .leading)
            }
            Text(finding.code)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Palette.inkTertiary)
                .truncationMode(.middle)
        }
        .font(.brimFacts)
        .lineLimit(1)
        .padding(.leading, 28)
        .padding(.vertical, 2)
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: description)
        .help(finding.code)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        let model = description.map { ". Apple Intelligence says: \($0)" } ?? ""
        return "\(finding.phrase), line \(finding.line)\(model). \(finding.code)"
    }
}
