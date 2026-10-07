import BrimCore
import BrimUI
import SwiftUI

/// One figure for each kind of space software takes, on one scale.
///
/// Remnants and Developer had a card each, side by side, with figures
/// that could not be compared with anything: 1.2 GB beside 27 GB, and
/// nothing to say what either was against the disk. Here every row is
/// a bar against the same used space, so the apps' share and a
/// removal's leftovers read as the sizes they are. What no row covers
/// is said as the subtraction it is, never estimated.
///
/// Removed items still in the Trash have their own row because Brim
/// put them there and they free nothing until the Trash is emptied.
struct SpaceSoftwareCard: View {
    @ObservedObject var storage: StorageModel
    @ObservedObject var applications: ApplicationsModel
    @ObservedObject var developer: DeveloperModel
    @ObservedObject var history: RemovalHistoryModel
    @ObservedObject var appData: AppDataModel
    @SwiftUI.Environment(ShellState.self) private var shell

    var body: some View {
        let rows = Self.rows(
            storage: storage, applications: applications, developer: developer, history: history, appData: appData
        )
        let used = storage.startupVolume?.used
        let counted = rows.compactMap(\.bytes).reduce(0, +)
        let scale = max(1, used ?? rows.compactMap(\.bytes).max() ?? 1)
        let everythingKnown = rows.allSatisfy { $0.bytes != nil }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("What software takes")
                    .font(.brimGroupTitle)
                    .foregroundStyle(Palette.ink)
                Spacer()
                if let used {
                    Text("Of \(ByteText.short(used)) used")
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            ForEach(rows) { row in
                softwareRow(row, scale: scale)
            }
            if let used, everythingKnown, used > counted {
                // Apple's own apps are not measured, so their data is here.
                Text("Everything else: your files, macOS and its apps, \(ByteText.short(used - counted))")
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .padding(8)
        .card()
        .hoverLift()
    }

    struct SoftwareRow: Identifiable {
        let title: String
        /// Nil while it is still being measured.
        let bytes: Int64?
        /// Shown instead of a size when there is one to say.
        var figure: String?
        let destination: Destination
        var id: String {
            title
        }
    }

    /// The rows, shared with the snapshot `SpaceView` records, so what is
    /// compared next visit is exactly what was shown.
    @MainActor
    static func rows(
        storage: StorageModel, applications: ApplicationsModel, developer: DeveloperModel,
        history: RemovalHistoryModel, appData: AppDataModel
    ) -> [SoftwareRow] {
        // Apps on another disk take nothing from this one.
        let apps = applications.applications.filter { !$0.isSystemProtected && !$0.url.path.hasPrefix("/Volumes/") }
        let measuring = appData.isMeasuring ? "Measuring \(appData.measured) of \(appData.toMeasure)" : nil
        var rows = [
            // A Mac always has apps, so an empty list is one not read yet.
            SoftwareRow(
                title: "Apps",
                bytes: applications.applications.isEmpty ? nil : apps.reduce(0) { $0 + $1.bundleSizeBytes },
                figure: applications.applications.isEmpty && applications.errorMessage != nil ? "Unavailable" : nil,
                destination: .apps
            ),
            SoftwareRow(
                title: "App data",
                bytes: appData.hasMeasured && !appData.isMeasuring ? appData.dataBytes : nil,
                figure: measuring ?? (appData.isIncomplete ? "At least " + ByteText.short(appData.dataBytes) : nil),
                destination: .apps
            ),
            SoftwareRow(
                title: "Developer caches",
                bytes: !developer.hasLoaded && developer.caches.isEmpty ? nil : developer.totalBytes,
                destination: .developer
            )
        ]
        if history.isLoading || history.bytesInTrash > 0 {
            rows.append(SoftwareRow(
                title: "Removed, in the Trash",
                bytes: history.isLoading ? nil : history.bytesInTrash,
                destination: .journal
            ))
        }
        rows.append(SoftwareRow(
            title: "Remnants",
            bytes: storage.hasEstimate ? storage.brimCanClear : nil,
            figure: storage.hasEstimate && storage.estimateUnavailable ? storage.brimCanClearFigure : nil,
            destination: .leftovers
        ))
        return rows
    }

    private func softwareRow(_ row: SoftwareRow, scale: Int64) -> some View {
        let figure = row.figure ?? row.bytes.map(ByteText.short) ?? "Checking"
        return Button {
            shell.go(to: row.destination)
        } label: {
            HStack(spacing: 12) {
                Text(row.title)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .frame(width: 170, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.well)
                        if let bytes = row.bytes, bytes > 0 {
                            Capsule()
                                .fill(Palette.snow)
                                .frame(width: max(3, proxy.size.width * min(1, Double(bytes) / Double(scale))))
                        }
                    }
                }
                .frame(height: 6)
                .brimAnimation(Motion.data, value: row.bytes)
                Text(figure)
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(row.bytes == nil ? Palette.inkTertiary : Palette.ink)
                    .frame(width: 92, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(.rect)
            .rowHighlight(isInspected: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.title), \(figure)")
        .accessibilityHint("Opens \(row.destination.rawValue)")
    }
}
