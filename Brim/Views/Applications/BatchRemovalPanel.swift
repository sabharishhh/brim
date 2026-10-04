import AppKit
import BrimCore
import BrimProtocol
import BrimUI
import SwiftUI

/// Several apps in one review. Each app keeps its own plan and its own
/// report; one press removes them in turn. See `BatchRemovalModel`.
struct BatchRemovalPanel: View {
    let apps: [InstalledApplication]
    let service: any BrimServiceProtocol
    /// Every app has been through its removal.
    var onRemoved: () -> Void = {}
    /// The panel is done with.
    let onFinished: () -> Void
    let onClose: () -> Void

    @StateObject private var model = BatchRemovalModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.entries) { entry in
                        BatchEntryRow(app: entry.app, removal: entry.removal)
                    }
                    if !model.isFinished {
                        Text("To change what is ticked for one app, review it on its own.")
                            .font(.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .task { await model.prepare(apps, service: service) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remove \(model.entries.count) apps")
                    .font(.brimPageTitle)
                    .foregroundStyle(Palette.ink)
                Text(model.isPreparing ? "Checking" : model.isFinished ? outcome : ByteText.short(model.totalBytes))
                    .font(.brimFacts)
                    .monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(model.isRemoving)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    /// "2 removed · 1 needs you", once they have all run.
    private var outcome: String {
        let done = model.entries.filter {
            if case let .verified(result) = $0.removal.phase {
                result.success
            } else {
                false
            }
        }.count
        let rest = model.entries.count - done
        return ["\(done) removed", rest > 0 ? "\(rest) \(rest == 1 ? "needs" : "need") you" : nil]
            .compactMap(\.self).joined(separator: " · ")
    }

    private var footer: some View {
        Group {
            if model.isFinished {
                Button("Done", action: onFinished)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(model.isRemoving ? "Removing" : "Remove \(model.ready.count) Apps") {
                    Task {
                        await model.removeAll(requesterIdentity: NSUserName())
                        onRemoved()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isPreparing || model.isRemoving || model.ready.isEmpty)
            }
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}

/// One app in the batch. Observes its own removal, because a model holding
/// other models does not pass their changes on.
private struct BatchEntryRow: View {
    let app: InstalledApplication
    @ObservedObject var removal: UninstallExecutionModel
    @State private var showsItems = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                BrimIcon(source: .bundle(app.url))
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.brimRowTitle)
                        .foregroundStyle(Palette.ink)
                    Text(status)
                        .font(.brimFacts)
                        .monospacedDigit()
                        .foregroundStyle(isTrouble ? Palette.caution : Palette.inkSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if removal.plan != nil {
                    Button(showsItems ? "Hide" : "Details") { showsItems.toggle() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)

            if showsItems {
                if case let .verified(result) = removal.phase {
                    RemovalResultView(result: result, plan: removal.plan, groups: removal.reviewGroups, scrolls: false)
                } else if removal.plan != nil {
                    // What the single review shows: files, not the records
                    // kept alongside them. A privacy reset listed here read as
                    // a file to be deleted permanently.
                    VStack(alignment: .leading, spacing: 2) {
                        if let installation = removal.plan?.homebrewInstallation {
                            Text(installation.explanation).font(.brimFacts)
                            if let command = installation.manualCommand {
                                Text(command).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        ForEach(removal.removalSteps, id: \.index) { step in
                            UninstallPlanRow(
                                target: step.target, evidence: step.evidence, bytes: step.expectedBytes,
                                disposition: step.effectiveDisposition, kind: step.kind, tier: step.tier
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Palette.surface.opacity(0.5), in: .rect(cornerRadius: Metrics.rowRadius))
    }

    private var status: String {
        switch removal.phase {
        case .preparing: return "Checking"
        case .ready:
            guard let plan = removal.plan else { return "Checking" }
            let steps = removal.removalSteps.count
            let count = steps == 1 ? "1 item" : "\(steps) items"
            return count + " · " + ByteText.short(plan.expectedTotalBytes) + " estimated"
        case .executing: return "Removing"
        case let .verified(result):
            guard result.success else { return "Some of it remains" }
            if (result.report?.scanCompleteness ?? removal.plan?.scanCompleteness)?.isComplete == false {
                return "Removed, search incomplete"
            }
            if let record = result.packageRecord, record.state != .absent {
                return record.state == .present
                    ? "Files removed, package record remains"
                    : "Files removed, package record unchecked"
            }
            if result.followUpActions?.isEmpty == false {
                return "One more step"
            }
            if result.report?.protectedItems.contains(where: { $0.presence == .unknown }) == true {
                return "Removed, protected items unchecked"
            }
            if result.report?.keptByMacOS.isEmpty == false || result.report?.protectedItems.isEmpty == false {
                return "Removed, protected or shared items remain"
            }
            if result.report?.sharedIdentityProtection != nil {
                return "Removed, privacy permissions not reset"
            }
            let unticked = result.report?.leftUnticked.count ?? 0
            return unticked == 0 ? "Nothing left" : "Removed, \(unticked) unticked stay"
        case .appliedButUnverified: return "Removed, not checked"
        case let .failed(why): return why
        }
    }

    private var isTrouble: Bool {
        switch removal.phase {
        case .failed, .appliedButUnverified: true
        case let .verified(result): !result.success
        default: false
        }
    }
}
