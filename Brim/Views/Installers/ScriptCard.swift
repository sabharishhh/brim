import BrimCore
import BrimUI
import SwiftUI

/// One install script, for someone who has never read one.
///
/// The model's plain summary leads, then Brim's own list of what the script
/// changes, each with its symbol. The lines themselves, with Brim's
/// technical phrase, the model's words for each and the code, open under
/// Show Details for whoever wants them. The model's words never replace
/// Brim's: a script can try to steer what is said about it.
struct ScriptCard: View {
    let script: InstallerPreview.Script
    @ObservedObject var scriptLines: ScriptLinesModel
    @State private var showsDetails = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !script.isText || script.findings.isEmpty {
                Text(script.isText ? "Calls nothing Brim looks for" : "A program, not readable as text")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                summary
                changes
                Button {
                    showsDetails.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showsDetails ? 90 : 0))
                        Text(showsDetails ? "Hide details" : "Show details")
                    }
                }
                .buttonStyle(DisclosureStyle())
                .accessibilityLabel(showsDetails ? "Hide details" : "Show details")
                if showsDetails {
                    lines
                        // A fade: sliding from the top drew the panel over the list
                        // above it while the card grew.
                        .transition(.opacity)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.well.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion), value: showsDetails)
        .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: scriptLines.summaries[script.id])
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 10) {
            ScriptMark(symbol: "terminal")
            VStack(alignment: .leading, spacing: 1) {
                Text(script.name)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text("Install script")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            if script.runsAsAdministrator {
                Label("As administrator", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.well, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let text = scriptLines.summaries[script.id] {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "apple.intelligence")
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("Summary by Apple Intelligence: \(text)")
            .transition(.opacity)
        } else if scriptLines.reading.contains(script.id) {
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBar(width: 340, height: 9)
                SkeletonBar(width: 230, height: 9)
            }
            .shimmer()
            .appearsAfterBriefWait()
            .transition(.opacity)
        }
    }

    private static let columns = [
        GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)
    ]

    /// Brim's own list, in two lean columns, each with its symbol.
    private var changes: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 10) {
            ForEach(InstallScriptReading.consequences(of: script.findings), id: \.self) { consequence in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: Self.symbol(for: consequence.phrase))
                        .font(.callout)
                        .foregroundStyle(Palette.snow)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(consequence.plain)
                        .font(.brimFacts)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(consequence.plain)
            }
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 0) {
            let shown = script.findings.prefix(ScriptLinesModel.shown)
            ForEach(Array(shown.enumerated()), id: \.element.line) { index, finding in
                if index > 0 {
                    Divider().opacity(0.5)
                }
                ScriptLineRow(
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
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Palette.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The symbol for each of Brim's phrases.
    static func symbol(for phrase: String) -> String {
        symbols[phrase] ?? "slider.horizontal.3"
    }

    private static let symbols: [String: String] = [
        "Starts or stops background jobs": "play.circle",
        "Installs a background service": "gearshape.2",
        "Loads a kernel extension": "cpu",
        "Changes system extensions": "puzzlepiece.extension",
        "Changes login items": "power.circle",
        "Resets privacy permissions": "hand.raised",
        "Changes Gatekeeper settings": "shield.lefthalf.filled",
        "Trusts a certificate": "checkmark.seal",
        "Installs a configuration profile": "doc.badge.gearshape",
        "Changes file attributes, such as quarantine": "exclamationmark.shield",
        "Downloads files": "arrow.down.circle",
        "Runs AppleScript": "applescript",
        "Quits running programs": "xmark.app",
        "Changes users or groups": "person.2",
        "Changes file ownership or permissions": "lock.open",
        "Deletes files": "trash",
        "Schedules a task": "calendar.badge.clock"
    ]
}

/// A symbol on a small rounded tile, as the script's mark.
private struct ScriptMark: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(Palette.snow)
            .frame(width: 30, height: 30)
            .background(Palette.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Show Details: a quiet capsule that lights on hover and gives a little
/// on press, so it reads as something to click.
private struct DisclosureStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DisclosureBody(configuration: configuration)
    }
}

private struct DisclosureBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.brimFacts)
            .foregroundStyle(isHovering ? Palette.ink : Palette.inkSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isHovering ? Palette.hover : Palette.well.opacity(0.6), in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
            .animation(Motion.quick, value: isHovering)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// One line that does something: Brim's phrase, the model's words for it,
/// and the line as written, to check either against.
private struct ScriptLineRow: View {
    let finding: InstallScriptReading.Finding
    let description: String?
    let isReading: Bool
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: ScriptCard.symbol(for: finding.phrase))
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 16)
                Text(finding.phrase)
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Text("Line \(finding.line)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkTertiary)
            }
            Group {
                if let description {
                    HStack(spacing: 5) {
                        Image(systemName: "apple.intelligence")
                            .foregroundStyle(Palette.inkTertiary)
                        Text(description)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    .transition(.opacity)
                } else if isReading {
                    SkeletonBar(width: 160, height: 7)
                        .shimmer()
                        .appearsAfterBriefWait()
                        .frame(height: 15, alignment: .leading)
                }
            }
            .padding(.leading, 24)
            Text(finding.code)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Palette.inkTertiary)
                .truncationMode(.middle)
                .padding(.leading, 24)
        }
        .font(.brimFacts)
        .lineLimit(1)
        .padding(.vertical, 8)
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
