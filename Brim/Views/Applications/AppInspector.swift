import BrimCore
import BrimUI
import SwiftUI

/// One app in depth: who made it, how it arrived, and everything it has
/// put on this Mac, grouped by what removing it would cost.
///
/// The footprint is a row of equal groups, App, Settings, Data and the
/// rest, and one of them is open at a time with its locations below. It
/// replaced a coloured size bar over one long list: the bar read as a
/// chart of what removal would free, and the list put the evidence for a
/// preferences file thirty rows from its group's name. Equal widths say
/// nothing about proportion, and coverage is said beside the groups rather
/// than folded into a total.
///
/// A `List`, not a scroll view over a stack, so each row is measured once.
struct AppInspector: View {
    let app: InstalledApplication
    @ObservedObject var model: ApplicationsModel
    @ObservedObject var access: FullDiskAccessModel
    let opened: String?
    let remove: () -> Void

    /// The group whose locations are showing, remembered across apps for
    /// this window: someone checking Data for one app usually wants Data
    /// for the next. An app without that group opens on its first.
    @SceneStorage("apps.footprintGroup") private var openGroup = FootprintLoss.app.rawValue
    /// Locations whose evidence is showing.
    @State private var detailed: Set<String> = []
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let installed: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

    /// "Installed 22 Sep · Opened 3 days ago", whichever Brim knows.
    private var dates: String {
        [app.installedAt.map { "Installed " + Self.installed.string(from: $0) }, opened]
            .compactMap(\.self).joined(separator: " · ")
    }

    private var sections: [FootprintSection] {
        model.isInspecting ? [] : model.footprintSections
    }

    /// The open group, falling back to the first that exists, so a stale
    /// choice never leaves the pane empty.
    private var shown: FootprintSection? {
        sections.first { $0.loss.rawValue == openGroup } ?? sections.first
    }

    var body: some View {
        List {
            Group {
                header
                actions
                footprintSummary
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            .listRowBackground(Color.clear)

            if let section = shown {
                Section {
                    ForEach(section.locations) { location in
                        LocationRow(
                            location: location, showsDetails: detailed.contains(location.id),
                            toggleDetails: { toggleDetails(location.id) }
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 14))
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    sectionHeader(section)
                }
                // A new group replaces the old one at once. Animated, the list
                // drew both groups on top of each other, and then scrolled the
                // incoming rows up under the group buttons for a moment before
                // settling. The selected button's indicator carries the motion.
                .id(section.id)
            }
            ListBottomSpacing()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func open(_ loss: FootprintLoss, animated _: Bool) {
        guard loss != shown?.loss else { return }
        var change = Transaction()
        change.disablesAnimations = true
        withTransaction(change) { openGroup = loss.rawValue }
    }

    private func toggleDetails(_ id: String) {
        withAnimation(Motion.resolved(Motion.openEvidence, reduceMotion: reduceMotion)) {
            detailed.formSymmetricDifference([id])
        }
    }

    private func sectionHeader(_ section: FootprintSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The same word as the group's button above it.
            Text(section.loss.navigationTitle)
                .font(.brimGroupTitle)
                .foregroundStyle(Palette.ink)
            Text(Self.facts(section))
                .font(.brimFacts)
                .monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// "3 locations · 12 MB", or "size not known" when any location's size
    /// was not measured, rather than a smaller total that looks complete.
    static func facts(_ section: FootprintSection) -> String {
        let count = section.locations.count == 1 ? "1 location" : "\(section.locations.count) locations"
        let sizes = section.locations.map(\.logicalBytes)
        guard !sizes.contains(where: { $0 == nil }) else { return count + " · size not fully known" }
        return count + " · " + ByteText.short(sizes.compactMap(\.self).reduce(0, +))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrimIcon(source: .bundle(app.url), size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                Text([app.developer, app.version.map { "Version \($0)" }].compactMap(\.self).joined(separator: " · "))
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            HStack(spacing: 8) {
                if let source = app.source {
                    StatusChip(text: source.title)
                }
                Text(dates)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let reason = model.uninstallBlockedReason {
            Label(reason, systemImage: "lock")
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
        } else {
            Button("Remove", action: remove)
                .capsuleAction(prominent: true)
                // Never disabled while the footprint loads: the review works out
                // its own plan, and a disabled button drawn at full strength
                // took a press and did nothing.
                .buttonBorderShape(.capsule)
            // Said before the press: removing it removes the app it ships in.
            if let host = app.enclosingApp {
                Label("Removed with \(host)", systemImage: "shippingbox")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    @ViewBuilder
    private var footprintSummary: some View {
        if model.isInspecting {
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBar(width: 140, height: 24)
                SkeletonBar(width: 260, height: 8)
                SkeletonRows(count: 4, showsTick: false)
            }
            .shimmer()
            .appearsAfterBriefWait()
            .padding(.top, 8)
            .accessibilityLabel("Checking")
        } else if let footprint = model.footprint {
            let places = sections.reduce(0) { $0 + $1.locations.count }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ByteText.short(footprint.totalSizeBytes))
                        .font(.brimFigure)
                        .foregroundStyle(Palette.ink)
                    Text(places == 1 ? "in 1 location" : "in \(places) locations")
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
                if !sections.isEmpty {
                    FootprintNavigator(
                        sections: sections, selected: shown?.loss ?? sections[0].loss
                    ) { loss, animated in
                        open(loss, animated: animated)
                    }
                }
                // Coverage is its own fact, beside the groups, never folded
                // into them: an unfinished search does not shrink a group.
                if let gap = footprint.completeness.explanation {
                    Label(gap, systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(Palette.caution)
                }
                if footprint.unreadableEntries > 0 {
                    unreadable(footprint.unreadableEntries)
                }
            }
            .padding(.top, 8)
        }
    }

    /// A total short by an amount Brim could not read says so, and names
    /// the one setting that fixes it when there is one.
    private func unreadable(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Label(
                access.isGranted
                    ? "\(count) protected by macOS, not counted"
                    : "\(count) behind Full Disk Access, not counted",
                systemImage: access.isGranted ? "lock" : "eye.slash"
            )
            .font(.caption)
            .foregroundStyle(Palette.caution)
            if !access.isGranted {
                Button("Open Settings") { FullDiskAccess.openSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

/// One place the app lives: Finder's icon, the path from ~, its size, and
/// an explicit Details control for how Brim knows it is the app's. The
/// evidence used to be hover help only, which a keyboard or VoiceOver user
/// never reached.
private struct LocationRow: View {
    let location: FootprintLocation
    let showsDetails: Bool
    let toggleDetails: () -> Void
    @SwiftUI.Environment(ShellState.self) private var shell

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrimIcon(source: .finder(location.url), size: 24)
                // The name first, then where it sits: two short lines read
                // better than one long path cut in the middle.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        // Identifiers differ at the end, so keep both ends.
                        Text(location.url.lastPathComponent)
                            .font(.brimFacts)
                            .foregroundStyle(Palette.ink)
                            .truncationMode(.middle)
                        if location.isShared {
                            StatusChip(text: "Shared")
                        }
                    }
                    Text(Self.abbreviated(location.url.deletingLastPathComponent().path))
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                .help(location.url.path)
                Spacer(minLength: 6)
                // Show in Finder lives in Details, the context menu and a
                // double-click. A hover-only button here took the room the
                // name needed and was never reachable from the keyboard.
                Text(size)
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize()
                Button(action: toggleDetails) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.inkTertiary)
                .help(showsDetails ? "Hide details" : "Details")
                .accessibilityLabel(showsDetails ? "Hide details" : "Details")
            }
            .padding(.horizontal, 10)
            .frame(height: 44)

            if showsDetails {
                evidence
                    .padding(.leading, 44)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .rowHighlight(isInspected: false)
        .contentShape(.rect)
        .onTapGesture(count: 2) { shell.showInFinder(location.url) }
        .contextMenu { ItemMenuItems(urls: [location.url]) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(location.url.lastPathComponent), \(size)\(location.isShared ? ", shared" : "")")
        .accessibilityValue(location.url.path)
        .accessibilityAction(named: "Show in Finder") { shell.showInFinder(location.url) }
    }

    /// Every record that names this place, strongest first, with what it
    /// means for the removal. A shared record is the one that keeps it.
    private var evidence: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(location.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.evidence.tier.shortLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.evidence.tier == .S ? Palette.caution : Palette.inkSecondary)
                        .fixedSize()
                    Text(item.evidence.humanSentence.isEmpty ? item.evidence.mechanism : item.evidence.humanSentence)
                        .font(.caption)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if location.isShared {
                Text("Another installed app uses this. It stays.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            if location.isPartial {
                Text("Part of it could not be read. It may be larger.")
                    .font(.caption)
                    .foregroundStyle(Palette.caution)
            }
            Button("Show in Finder") { shell.reveal([location.url]) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var size: String {
        // Says why there is no figure: not measured yet, or two records
        // that disagree, neither of which Brim picks between.
        if let bytes = location.logicalBytes {
            return ByteText.short(bytes)
        }
        return location.isUnmeasured ? "Not measured" : "Sizes differ"
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
