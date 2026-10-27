import BrimCore
import BrimOps
import Foundation

struct DockShortcutReview {
    let pins: Set<String>
    let failure: String?

    init(root: FileSystemRoot) {
        do {
            pins = try DockShortcuts.pinnedPaths(in: root)
            failure = nil
        } catch {
            pins = []
            failure = "Dock shortcuts could not be checked: \(error.localizedDescription)"
        }
    }
}

struct DockShortcutVerification {
    let completed: [String]
    let failures: [String]
    var isComplete: Bool {
        failures.isEmpty
    }

    init(plan: Plan, root: FileSystemRoot) {
        let steps = plan.steps.filter { $0.kind == .removeDockShortcut }
        let pins = steps.isEmpty ? Set<String>() : try? DockShortcuts.pinnedPaths(in: root)
        completed = steps.filter { pins?.contains($0.target) == false }
            .map { "Dock shortcut removed for " + $0.target }
        failures = [plan.dockShortcutReadError].compactMap(\.self) + steps.compactMap { step -> String? in
            guard pins?.contains(step.target) != false else { return nil }
            return pins == nil ? "Could not check the Dock shortcut for \(step.target)."
                : "Dock shortcut is still pinned for \(step.target)."
        }
    }
}

extension Executor {
    static func removeDockShortcut(
        step: Step, plan: Plan, outcomes: [Int: String], client: DockShortcuts.Client
    ) async throws {
        guard plan.steps.contains(where: {
            [.trashPath, .trashPathPrivileged].contains($0.kind) && $0.target == step.target
                && ["ok", "already_gone"].contains(outcomes[$0.index] ?? "")
        }), PathObservation.observe(step.target).isAbsent else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try await client.remove(step.target)
    }
}
