import BrimCore
import BrimPrivileged
import BrimProtocol
import BrimUI
import SwiftUI

/// First run, and the only place Brim asks the person for anything.
///
/// Everything it needs is settled here, in one sitting, while they are
/// paying attention to setup rather than in the middle of looking at
/// something. After this the app is quiet: no permission dialog between a
/// person and a list they asked to see, and no fingerprint before anything
/// that can be undone.
///
/// It is setup, not a gate. Every step can be skipped and the app still
/// opens and works, because a scan without Full Disk Access is not wrong,
/// it is smaller, and it says so.
///
/// The step is remembered. Turning on Full Disk Access makes macOS quit
/// Brim, and setup used to start again from the welcome when it reopened,
/// as though nothing had happened.
struct OnboardingSheet: View {
    let service: any BrimServiceProtocol
    /// Scanning behind the sheet, so the helper step can say what it would
    /// do on this Mac rather than in general.
    @ObservedObject var leftovers: LeftoversModel
    let onFinished: () -> Void

    enum Step: Int, CaseIterable {
        case what, access, helper, confirm, ready
    }

    @AppStorage("onboarding.step") private var savedStep = Step.what.rawValue
    @StateObject private var access = FullDiskAccessModel()
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// Read by the helper step, in `OnboardingSheet+Helper.swift`.
    @State var helperState: PrivilegedHelperClient.State?
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var step: Step {
        Step(rawValue: savedStep) ?? .what
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .id(step)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: reduceMotion ? 0 : 16)),
                    removal: .opacity
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(28)
        // Fixed, so the sheet never asks the window to re-measure it
        // (`CLAUDE.md`, on scrolling review sheets).
        .frame(width: 560, height: 470)
        .onAppear { access.startObserving() }
        .onDisappear { access.stopObserving() }
    }

    private func go(to next: Step) {
        withAnimation(Motion.resolved(Motion.standard, reduceMotion: reduceMotion)) {
            savedStep = next.rawValue
        }
    }

    private func finish() {
        savedStep = Step.what.rawValue
        onFinished()
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .what: whatBrimDoes
        case .access: fullDiskAccess
        case .helper: helperStep
        case .confirm: confirmOwnership
        case .ready: ready
        }
    }

    private var whatBrimDoes: some View {
        VStack(alignment: .leading, spacing: 22) {
            title("Welcome to Brim", "Finds what software leaves behind, and proves it is gone")
            VStack(alignment: .leading, spacing: 16) {
                point(
                    "magnifyingglass", "Looks where uninstalls miss", "Login items, background jobs, settings, caches"
                )
                point("checkmark.seal", "Checks its own work", "Every place is read again after a removal")
                point("arrow.uturn.backward", "Almost everything comes back", "Removals go to the Trash first")
            }
        }
    }

    private var fullDiskAccess: some View {
        VStack(alignment: .leading, spacing: 22) {
            title("Full Disk Access", "The one setting Brim asks for")
            if access.isGranted {
                status("checkmark.circle.fill", .accentColor, "On", "Everything Brim needs can be read")
            } else {
                status("lock.fill", Palette.caution, "Off", "Containers and login items stay hidden until it is on")
                Button {
                    access.requestAccess()
                } label: {
                    Label("Open System Settings", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                if access.hasRequested {
                    Text("Switch Brim on. Setup carries on here when macOS reopens it.")
                        .font(.brimFacts)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var confirmOwnership: some View {
        VStack(alignment: .leading, spacing: 22) {
            title("One check", "Confirms this Mac is yours, so Brim can stay quiet later")
            VStack(alignment: .leading, spacing: 16) {
                point("trash", "No prompt for the Trash", "It can all be put back")
                point("touchid", "One prompt for anything permanent", "Once per removal, then quiet for five minutes")
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.brimFacts)
                    .foregroundStyle(Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, options: .nonRepeating, value: step)
            Text("Ready")
                .font(.brimHeadline)
                .foregroundStyle(Palette.ink)
            HStack(spacing: 10) {
                StatusChip(
                    text: access.isGranted ? "Full Disk Access on" : "Full Disk Access off",
                    symbol: access.isGranted ? "checkmark" : "lock", tone: access.isGranted ? .accent : .caution
                )
                StatusChip(
                    text: helperState == .ready ? "Helper on" : "Helper off",
                    symbol: helperState == .ready ? "checkmark" : "minus",
                    tone: helperState == .ready ? .accent : .neutral
                )
            }
            Text("Both can be changed later in Settings")
                .font(.brimFacts)
                .foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onAppear { helperState = HelperRoute.currentState() }
    }

    // MARK: - Chrome

    func title(_ heading: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.brimHeadline)
                .foregroundStyle(Palette.ink)
            Text(detail)
                .font(.body)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func point(_ symbol: String, _ heading: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(heading). \(detail)")
    }

    func status(_ symbol: String, _ tint: Color, _ heading: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading)
                    .font(.brimRowTitle)
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.brimFacts)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: Metrics.rowRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(heading). \(detail)")
    }

    private func enroll() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.enroll()
            go(to: .ready)
        } catch {
            // Declining is not a failure worth blocking on, since nothing
            // depends on it. Say so plainly and let them carry on.
            errorMessage = error.localizedDescription
        }
    }
}

extension OnboardingSheet {
    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { each in
                    Capsule()
                        .fill(each == step ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.well))
                        .frame(width: each == step ? 16 : 6, height: 6)
                }
            }
            .animation(Motion.resolved(Motion.quick, reduceMotion: reduceMotion), value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            Spacer()

            if isWorking {
                ProgressView().controlSize(.small)
            }
            if step != .what, step != .ready {
                Button("Back") { go(to: Step(rawValue: step.rawValue - 1) ?? .what) }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
            }
            buttons
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private var buttons: some View {
        switch step {
        case .what:
            primary("Continue") { go(to: .access) }
        case .access:
            // Skipping is a real choice, so it is the plain button until
            // the setting is on and continuing is the obvious next move.
            if access.isGranted {
                primary("Continue") { go(to: .helper) }
            } else {
                secondary("Skip") { go(to: .helper) }
            }
        case .helper:
            if helperState == .ready {
                primary("Continue") { go(to: .confirm) }
            } else {
                secondary("Skip") { go(to: .confirm) }
            }
        case .confirm:
            Button("Not Now") { go(to: .ready) }
                .buttonStyle(.glass)
                .disabled(isWorking)
            primary("Confirm") { Task { await enroll() } }
                .disabled(isWorking)
        case .ready:
            primary("Open Brim", action: finish)
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.glass)
            .keyboardShortcut(.defaultAction)
    }
}
