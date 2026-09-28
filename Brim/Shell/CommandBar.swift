import BrimCore
import BrimUI
import SwiftUI

/// ⌘K: go anywhere, find any app or leftover, or run a command, from the
/// keyboard. Glass, because it floats over the page it acts on.
struct CommandBar: View {
    let shell: ShellState
    @ObservedObject var applications: ApplicationsModel
    @ObservedObject var leftovers: LeftoversModel

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    private struct Result: Identifiable {
        let id: String
        let title: String
        let kind: String
        let icon: IconSource?
        let symbol: String
        let run: () -> Void
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.inkSecondary)
                TextField("Go to, find an app or leftover", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .accessibilityLabel("Go to or find")
                    .onSubmit { run(results) }
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            if !results.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            // A real button, so a click, a VoiceOver press
                            // and Full Keyboard Access all run it.
                            Button {
                                highlighted = index
                                run(results)
                            } label: {
                                row(result, isHighlighted: index == highlighted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.cardRadius))
        .onAppear { isFocused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            shell.showsCommandBar = false
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command bar")
    }

    private func row(_ result: Result, isHighlighted: Bool) -> some View {
        HStack(spacing: 12) {
            if let icon = result.icon {
                BrimIcon(source: icon, size: Metrics.compactRowIcon)
            } else {
                Image(systemName: result.symbol)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: Metrics.compactRowIcon, height: Metrics.compactRowIcon)
            }
            Text(result.title)
                .font(.brimRowTitle)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer()
            Text(result.kind)
                .font(.caption)
                .foregroundStyle(Palette.inkTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(
            isHighlighted ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(Color.clear),
            in: .rect(cornerRadius: 10, style: .continuous)
        )
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityLabel("\(result.title), \(result.kind)")
    }

    private func run(_ results: [Result]) {
        guard results.indices.contains(highlighted) else { return }
        shell.showsCommandBar = false
        results[highlighted].run()
    }

    // MARK: - Results

    /// Pages and commands first, then apps, then leftovers, a few of each.
    private var results: [Result] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let matches: (String) -> Bool = { text.isEmpty || $0.localizedCaseInsensitiveContains(text) }

        var results = Destination.displayOrder.filter { matches($0.rawValue) }.map { destination in
            Result(
                id: "page:" + destination.rawValue, title: destination.rawValue, kind: "Page", icon: nil,
                symbol: destination.icon, run: { shell.go(to: destination) }
            )
        }
        if matches("Check Again") {
            results.append(Result(
                id: "check", title: "Check Again", kind: "Command", icon: nil, symbol: "arrow.clockwise",
                run: { shell.requestCheck() }
            ))
        }
        guard !text.isEmpty else { return results }

        results += applications.applications.filter { matches($0.name) }.prefix(6).map { app in
            Result(
                id: "app:" + app.id, title: app.name, kind: "App", icon: .bundle(app.url), symbol: "app",
                run: {
                    shell.go(to: .apps, lens: .all)
                    _ = applications.selectApplication(at: app.url)
                }
            )
        }
        results += (leftovers.orphanedGroups + leftovers.unclaimedGroups).filter { matches($0.displayName) }
            .prefix(5).map { group in
                Result(
                    id: "leftover:" + group.id, title: group.displayName, kind: "Leftover", icon: group.ownerIcon,
                    symbol: "shippingbox",
                    run: {
                        shell.go(to: .leftovers)
                        leftovers.inspected = group
                    }
                )
            }
        return results
    }
}
