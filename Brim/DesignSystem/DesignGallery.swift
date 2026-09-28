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

        private struct Sample: Identifiable {
            let id: String
            let icon: IconSource
            let title: String
            let facts: String
            let bytes: Int64
            var badge: IconBadge?
            var isNew = false
        }

        @State private var showsAll = false
        @State private var trayCount = 3
        @State private var work: BrimLine.Work = .fraction(0.4)

        private let apps: [URL] = {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
            return names.filter { $0.hasSuffix(".app") }.sorted().prefix(10)
                .map { URL(fileURLWithPath: "/Applications").appendingPathComponent($0) }
        }()

        private let caches = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")

        private var samples: [Sample] {
            var rows = apps.enumerated().map { index, url in
                Sample(
                    id: url.path, icon: .bundle(url), title: url.deletingPathExtension().lastPathComponent,
                    facts: "Opened \(index + 1) months ago", bytes: Int64(900_000_000 / (index + 1)),
                    badge: index == 2 ? .kept : nil, isNew: index == 1
                )
            }
            rows.append(Sample(
                id: "monogram", icon: .monogram(Monogram(name: "Parallels Toolbox")),
                title: "Parallels Toolbox", facts: "Removed in March", bytes: 12_000_000, badge: .removed
            ))
            return rows
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    section("Type") {
                        Text("Four apps you removed left 2.1 GB behind.").font(.brimHeadline)
                        Text("Leftovers").font(.brimPageTitle)
                        Text("Monday 28 September").font(.brimDayHeader)
                        Text("Not opened since June · 7 apps · 12.4 GB").font(.brimFacts)
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
                            BrimIcon(source: .monogram(Monogram(name: "New")), size: 32, isNew: true)
                        }
                    }
                    section("Chips") {
                        HStack {
                            StatusChip(text: "Kept", symbol: "pin.fill")
                            StatusChip(text: "In the tray", symbol: "tray", tone: .accent)
                            StatusChip(text: "Needs the helper", symbol: "lock.fill", tone: .caution)
                        }
                        SizeBar(fraction: 0.62).frame(width: 120)
                    }
                    section("Stack") {
                        StackCard(
                            title: "Not opened in 3 months",
                            summary: "\(samples.count) apps · \(ByteText.short(samples.map(\.bytes).reduce(0, +)))",
                            items: samples, showsAll: $showsAll
                        ) { sample in
                            StackRow(
                                icon: sample.icon, badge: sample.badge, isNew: sample.isNew, title: sample.title,
                                facts: sample.facts, bytes: sample.bytes,
                                sizeFraction: Double(sample.bytes) / Double(samples.map(\.bytes).max() ?? 1)
                            ) {
                                EmptyView()
                            } actions: {
                                Button("Keep") {}
                                Button("Add to Tray") {}
                            }
                        }
                        .frame(maxWidth: 640)
                    }
                    section("Tiles") {
                        HStack(spacing: 16) {
                            Tile(title: "Leftovers", figure: "2.1 GB", caption: "from 14 apps",
                                 icons: apps.prefix(3).map { .bundle($0) }) {}
                            Tile(title: "Background", figure: "23", caption: "2 with no app") {}
                            Tile(title: "Space", figure: "212 GB free", caption: "of 994 GB") {}
                        }
                        .frame(maxWidth: 760)
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
                            EmptyState.nothingFound("Nothing is left behind", placesChecked: 214)
                            EmptyState.notChecked("leftovers") {}
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
