import BrimCore
import BrimUI
import SwiftUI

/// The apps that take the most, counting what each keeps outside its
/// bundle.
///
/// Ranked by bundle alone, this list hid where the space was: Claude's
/// bundle is 0.9 GB and the data it keeps is 13 GB, WhatsApp's 0.7 GB and
/// 4.1 GB. Each bar is two tones on one scale, the bundle in off-white and
/// its data in grey, so a small app with a large store reads as what it
/// is. Until the data is measured the list ranks by bundle and says so.
struct SpaceLargestApps: View {
    @ObservedObject var applications: ApplicationsModel
    @ObservedObject var appData: AppDataModel
    @SwiftUI.Environment(ShellState.self) private var shell

    private var rows: [AppData] {
        if appData.hasMeasured {
            return Array(appData.apps.sorted { $0.totalBytes > $1.totalBytes }.prefix(5))
        }
        return Array(applications.applications.filter { !$0.isSystemProtected }
            .sorted { $0.bundleSizeBytes > $1.bundleSizeBytes }
            .prefix(5)
            .map { AppData(name: $0.name, bundlePath: $0.url.path, bundleBytes: $0.bundleSizeBytes, dataBytes: 0) })
    }

    var body: some View {
        let rows = rows
        let scale = max(1, rows.map(\.totalBytes).max() ?? 1)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Largest apps")
                        .font(.brimGroupTitle)
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    if appData.hasMeasured {
                        key(Palette.snow, "App")
                        key(Palette.frost, "Its data")
                    } else {
                        Text("By app size")
                            .font(.brimFacts)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    Button("Show all") { shell.go(to: .apps, lens: .all) }
                        .buttonStyle(.borderless)
                        .font(.brimFacts)
                        .padding(.leading, 8)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                ForEach(rows) { app in
                    row(app, scale: scale)
                }
            }
            .padding(8)
            .card()
            .hoverLift()
        }
    }

    private func key(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 6)
            Text(title)
        }
        .font(.brimFacts)
        .foregroundStyle(Palette.inkSecondary)
        .accessibilityHidden(true)
    }

    private func row(_ app: AppData, scale: Int64) -> some View {
        Button {
            shell.go(to: .apps, lens: .all)
            _ = applications.selectApplication(at: URL(fileURLWithPath: app.bundlePath))
        } label: {
            HStack(spacing: 12) {
                BrimIcon(source: .bundle(URL(fileURLWithPath: app.bundlePath)), size: Metrics.compactRowIcon)
                Text(app.name)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        Capsule()
                            .fill(Palette.snow)
                            .frame(width: max(3, proxy.size.width * Double(app.bundleBytes) / Double(scale)))
                        if app.dataBytes > 0 {
                            Capsule()
                                .fill(Palette.frost)
                                .frame(width: max(3, proxy.size.width * Double(app.dataBytes) / Double(scale)))
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 6)
                Text(ByteText.short(app.totalBytes))
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 80, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(.rect)
            .rowHighlight(isInspected: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.name)
        .accessibilityValue(spoken(app))
    }

    private func spoken(_ app: AppData) -> String {
        let total = ByteText.short(app.totalBytes)
        guard app.dataBytes > 0 else { return total }
        return "\(total): app \(ByteText.short(app.bundleBytes)), data \(ByteText.short(app.dataBytes))"
    }
}
