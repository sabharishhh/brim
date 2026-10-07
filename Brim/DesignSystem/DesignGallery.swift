import BrimCore
import BrimUI
import SwiftUI

#if DEBUG
    /// Every design system component on one page, with real icons from this
    /// Mac, so the foundations can be looked at before any screen uses them.
    ///
    /// Debug builds only. Launch with `-designGallery YES` to open it instead
    /// of the app.
    struct DesignGallery: View {
        static var isRequested: Bool {
            UserDefaults.standard.bool(forKey: "designGallery")
        }

        @State private var trayCount = 3
        @State private var work: BrimLine.Work = .fraction(0.4)

        private let apps: [URL] = {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
            return names.filter { $0.hasSuffix(".app") }.sorted().prefix(10)
                .map { URL(fileURLWithPath: "/Applications").appendingPathComponent($0) }
        }()

        private let caches = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    section("Type") {
                        Text("Four apps you removed left 2.1 GB behind.").font(.brimHeadline)
                        Text("Leftovers").font(.brimPageTitle)
                        Text("Monday 28 September").font(.brimDayHeader)
                        Text("Your apps · 42 · 12.4 GB").font(.brimFacts)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    section("Palette") {
                        HStack(spacing: 8) {
                            ForEach(Palette.hues.indices, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 8).fill(Palette.hues[index]).frame(width: 40, height: 40)
                            }
                            RoundedRectangle(cornerRadius: 8).fill(.tint).frame(width: 40, height: 40)
                        }
                    }
                    section("Icons") {
                        HStack(spacing: 14) {
                            if let first = apps.first {
                                BrimIcon(source: .bundle(first), size: 44)
                            }
                            BrimIcon(source: .finder(caches), size: 44)
                            BrimIcon(source: .remembered(bundleID: "com.example.gone"), size: 44)
                            ForEach(["Docker", "Visual Studio Code", "OneDrive", "Zoom"], id: \.self) { name in
                                BrimIcon(source: .monogram(Monogram(name: name)), size: 44)
                            }
                        }
                        HStack(spacing: 14) {
                            ForEach(ItemKind.allCases, id: \.self) { kind in
                                BrimIcon(source: .symbol(kind), size: 32)
                            }
                        }
                        HStack(spacing: 14) {
                            ForEach(IconBadge.allCases, id: \.self) { badge in
                                BrimIcon(source: .monogram(Monogram(name: badge.rawValue)), size: 32, badge: badge)
                            }
                        }
                    }
                    section("Chips") {
                        HStack {
                            StatusChip(text: "Shared")
                            StatusChip(text: "Full Disk Access on", symbol: "checkmark", tone: .accent)
                            StatusChip(text: "Needs administrator access", symbol: "lock.fill", tone: .caution)
                        }
                    }
                    section("Work and freshness") {
                        BrimLine(work: work).frame(width: 300)
                        HStack {
                            Button("Idle") { work = .idle }
                            Button("Working") { work = .indeterminate }
                            Button("70%") { work = .fraction(0.7) }
                        }
                        FreshnessLabel(freshness: .checked(.now.addingTimeInterval(-7200)))
                        FreshnessLabel(freshness: .partial(.now.addingTimeInterval(-300), unread: 3))
                        FreshnessLabel(freshness: .checked(.now.addingTimeInterval(-3 * 86400)))
                    }
                    section("Glass") {
                        TrayBar(count: trayCount, bytes: Int64(trayCount) * 340_000_000,
                                review: { trayCount += 1 }, clear: { trayCount = 1 })
                        Toast(symbol: "checkmark.circle.fill", message: "Moved 12 items to the Trash",
                              actionTitle: "Put Back") {}
                    }
                    section("Empty states") {
                        HStack(alignment: .top) {
                            EmptyState(symbol: "checkmark.circle", title: "Nothing left behind",
                                       message: "No removed app has left anything on this Mac.")
                            EmptyState.couldNotRead("Full Disk Access is off, so Library could not be read.") {}
                        }
                        .frame(height: 220)
                    }
                }
                .padding(Metrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.canvas)
            .frame(minWidth: 900, minHeight: 600)
        }

        private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
                content()
            }
        }
    }
#else
    struct DesignGallery: View {
        static let isRequested = false
        var body: some View {
            EmptyView()
        }
    }
#endif
