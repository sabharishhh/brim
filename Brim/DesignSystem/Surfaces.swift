import BrimCore
import BrimUI
import SwiftUI

// MARK: - The brim line

/// One hairline under the toolbar that fills while Brim works. Brim's only
/// brand motif, and its main progress indicator.
///
/// Idle, it is a plain hairline and nothing on it moves.
struct BrimLine: View {
    enum Work: Equatable {
        case idle
        /// Working with no way to know how far along.
        case indeterminate
        case fraction(Double)
    }

    let work: Work
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 2)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    switch work {
                    case .idle:
                        EmptyView()
                    case let .fraction(fraction):
                        Rectangle()
                            .fill(.tint)
                            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                            .brimAnimation(Motion.data, value: fraction)
                    case .indeterminate:
                        if reduceMotion {
                            Rectangle().fill(.tint.opacity(0.5))
                        } else {
                            // Only while working: the timeline stops when
                            // this case goes, so an idle window draws nothing.
                            TimelineView(.animation) { context in
                                let period = 1.4
                                let phase = context.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: period) / period
                                let width = proxy.size.width * 0.3
                                Rectangle()
                                    .fill(.tint)
                                    .frame(width: width)
                                    .offset(x: (proxy.size.width + width) * phase - width)
                            }
                        }
                    }
                }
            }
            .clipped()
            .transition(.opacity)
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch work {
        case .idle: "Idle"
        case .indeterminate: "Working"
        case let .fraction(fraction): "\(Int(fraction * 100)) percent done"
        }
    }
}

// MARK: - Freshness

/// How old what a surface shows is: "Checked 2 hours ago".
///
/// Re-rendered once a minute, which is text changing rather than anything
/// animating, and only while the age is one that changes.
struct FreshnessLabel: View {
    let freshness: Freshness

    var body: some View {
        switch freshness {
        case .checked, .partial:
            TimelineView(.periodic(from: .now, by: 60)) { context in
                label(freshness.sentence(now: context.date))
            }
        default:
            label(freshness.sentence())
        }
    }

    private func label(_ text: String) -> some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(Palette.caution)
            }
            Text(text)
        }
        .font(.brimFacts)
        .foregroundStyle(freshness.isStale() && freshness != .checking ? Palette.caution : Palette.inkSecondary)
    }

    private var symbol: String? {
        switch freshness {
        case .partial, .failed: "exclamationmark.triangle.fill"
        default: nil
        }
    }
}

// MARK: - Empty states

/// What a surface says when it has no rows, which is never just blank.
///
/// Three different facts, kept apart on purpose: Brim looked and found
/// nothing, Brim has not looked, and Brim could not look. A zero that was
/// never measured is a lie (`CLAUDE.md`).
struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
            }
        }
        .foregroundStyle(Palette.ink)
    }

    static func nothingFound(_ title: String, placesChecked: Int) -> EmptyState {
        EmptyState(
            symbol: "checkmark.seal", title: title,
            message: "Brim checked \(placesChecked) places."
        )
    }

    static func notChecked(_ what: String, action: @escaping () -> Void) -> EmptyState {
        EmptyState(
            symbol: "magnifyingglass", title: "Not checked yet",
            message: "Brim has not looked for \(what) on this Mac.",
            actionTitle: "Check Now", action: action
        )
    }

    static func couldNotRead(_ reason: String, action: @escaping () -> Void) -> EmptyState {
        EmptyState(
            symbol: "lock", title: "Brim could not look",
            message: reason, actionTitle: "Try Again", action: action
        )
    }
}

// MARK: - Tray

/// The capsule at the bottom of a workspace holding what the person has
/// picked to remove. Glass, because it floats over the content it
/// collects from.
struct TrayBar: View {
    let count: Int
    let bytes: Int64
    let review: () -> Void
    let clear: () -> Void

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                Image(systemName: "tray.full")
                    .foregroundStyle(.tint)
                Text(count == 1 ? "1 item" : "\(count) items")
                    .contentTransition(.numericText(value: Double(count)))
                Text(ByteText.short(bytes))
                    .foregroundStyle(Palette.inkSecondary)
                    .contentTransition(.numericText(value: Double(bytes)))
                Button("Clear", action: clear)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Palette.inkSecondary)
                Button("Review", action: review)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .font(.body.weight(.medium))
            .monospacedDigit()
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .animation(Motion.resolved(Motion.emphasis, reduceMotion: reduceMotion), value: count)
    }
}

// MARK: - Toast

/// A short note about something that just happened, with the one action
/// that undoes it.
struct Toast: View {
    let symbol: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text(message)
                .foregroundStyle(Palette.ink)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
            }
        }
        .font(.body)
        .padding(.leading, 16)
        .padding(.trailing, actionTitle == nil ? 16 : 6)
        .padding(.vertical, 8)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .combine)
    }
}
