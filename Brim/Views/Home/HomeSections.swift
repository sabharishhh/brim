import BrimCore
import BrimUI
import SwiftUI

/// What changed since Brim last looked: two snapshots, subtracted.
///
/// "Since Brim last looked" rather than "since your last visit": the
/// comparison is between enumerations, and saying which is the honest
/// version of the same promise. One snapshot means nothing to compare,
/// which is said as that rather than as "nothing changed".
struct SinceLastLook: View {
    let history: InstallHistory
    let applications: [InstalledApplication]
    /// Leftovers that were not there the last time the list was seen.
    var newLeftovers = 0
    var openLeftovers: () -> Void = {}

    @State private var showsAll = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let shown = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Since Brim last looked")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                if let since = history.changes.first?.since {
                    Text(Self.day(since))
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if newLeftovers > 0 {
                Button(action: openLeftovers) {
                    line(
                        .symbol(.folder),
                        newLeftovers == 1 ? "1 new leftover" : "\(newLeftovers) new leftovers"
                    )
                }
                .buttonStyle(.press)
            }
            if history.snapshots < 2 {
                note("This is Brim's first look at this Mac. Next time, what changed shows here.")
            } else if history.changes.isEmpty, newLeftovers == 0 {
                note("Nothing was installed, removed or updated.")
            } else {
                ForEach(visible, id: \.bundleID) { change in
                    line(icon(for: change), change.sentence)
                        .transition(.brimRow(reduceMotion: reduceMotion))
                }
                if history.changes.count > Self.shown {
                    Button {
                        withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
                            showsAll.toggle()
                        }
                    } label: {
                        Text(showsAll ? "Show fewer" : "and \(history.changes.count - Self.shown) more")
                            .font(.brimFacts.weight(.medium))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.press)
                }
            }
        }
        .padding(Metrics.cardPadding)
        .card()
    }

    private var visible: [InstallChange] {
        showsAll ? history.changes : Array(history.changes.prefix(Self.shown))
    }

    private func line(_ icon: IconSource, _ text: String) -> some View {
        HStack(spacing: 12) {
            BrimIcon(source: icon, size: Metrics.compactRowIcon)
            Text(text)
                .font(.body)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.compactRowHeight)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.brimFacts)
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    /// The app's own icon while it is installed, the saved one once it is
    /// gone, and its monogram when Brim never saw it.
    private func icon(for change: InstallChange) -> IconSource {
        let installed = applications.first { $0.identity.bundleID == change.bundleID }
        return IconResolver.source(
            for: IconSubject(
                name: change.name, kind: .application,
                ownerName: change.name, ownerBundleID: change.bundleID, ownerURL: installed?.url
            ),
            remembered: { IconMemory.standard.has($0) }
        )
    }

    /// "today", "Monday" or "3 September". Built once, not per draw.
    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return formatter
    }()

    static func day(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return "earlier today"
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return weekday.string(from: date)
        }
        return Self.date.string(from: date)
    }
}

/// Where an app is dropped to open everything it put on this Mac. Glass
/// only while something is over it, which is when it is a control.
struct DropWell: View {
    let onDrop: ([URL]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.app")
                .font(.title2)
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.inkTertiary))
                .symbolEffect(.bounce, value: isTargeted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop an app here")
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text("to see everything it put on this Mac.")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(
                    isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.inkTertiary.opacity(0.5)),
                    style: StrokeStyle(lineWidth: 1.5, dash: isTargeted ? [] : [6, 5])
                )
        }
        .glassEffect(
            isTargeted ? .regular.tint(.accentColor.opacity(0.12)) : .identity,
            in: .rect(cornerRadius: Metrics.cardRadius)
        )
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
        } isTargeted: { isTargeted = $0 }
        .animation(Motion.quick, value: isTargeted)
        .accessibilityElement(children: .combine)
    }
}
