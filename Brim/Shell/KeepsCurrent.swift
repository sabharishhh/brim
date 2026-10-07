import AppKit
import BrimUI
import SwiftUI

/// Keeps every page current while Brim's window is open, without anyone
/// pressing Check Again and without reading anything on a timer that macOS
/// could have announced.
///
/// - The Applications folders are watched. An install, an update or a
///   removal changes the Apps list within about two seconds; an app that
///   arrived or left makes Remnants stale, and Updates drops a row the disk
///   has already answered.
/// - The background job folders and the Background Task Management store
///   are watched, so a login item or launch agent appears or goes while
///   Background is open.
/// - Coming back to Brim, or the Mac waking, catches up what has no event:
///   privacy entries edited in System Settings, a Remnants result over half
///   an hour old, an Updates check past its age, free space.
/// - Free space is read every thirty seconds while Space or Home is shown,
///   and when a disk is mounted or ejected.
///
/// All of it lives as long as the window's tasks and stops with them, so
/// nothing watches once Brim has quit.
struct KeepsCurrent: ViewModifier {
    let models: SectionModels
    let shell: ShellState
    @SwiftUI.Environment(\.brimService) private var service

    func body(content: Content) -> some View {
        content
            .task { await followApplications() }
            .task { await followBackground() }
            .task(id: shell.selection) { await followFreeSpace() }
            .onReceive(models.applications.$applications) { models.updates.reconcile(with: $0) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await catchUp() }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task { await catchUp() }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
                Task { await models.storage.readVolumes(service: service) }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
                Task { await models.storage.readVolumes(service: service) }
            }
    }

    /// Pages that show what Remnants found.
    private var showsRemnants: Bool {
        [.home, .leftovers, .space].contains(shell.selection)
    }

    private func followApplications() async {
        var known = ApplicationFolders.signature()
        for await _ in FolderWatch.changes(in: ApplicationFolders.standard) {
            let now = ApplicationFolders.signature()
            guard now != known else { continue }
            let arrivedOrLeft = Set(now.keys) != Set(known.keys)
            known = now
            await models.applications.load(service: service)
            if arrivedOrLeft {
                models.leftovers.markStale()
                if showsRemnants {
                    await models.leftovers.loadIfNeeded(service: service)
                }
            }
        }
    }

    private func followBackground() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [
            home.appendingPathComponent("Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons"),
            URL(fileURLWithPath: "/var/db/com.apple.backgroundtaskmanagement")
        ]
        for await _ in FolderWatch.changes(in: folders) {
            // Not yet looked at is not stale; Background reads when opened.
            guard models.background.hasLoaded else { continue }
            await models.background.load(service: service, applications: models.applications.applications)
        }
    }

    private func followFreeSpace() async {
        guard [.space, .home].contains(shell.selection) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, AppVisibility.isVisible else { continue }
            await models.storage.readVolumes(service: service)
        }
    }

    /// What has no event of its own, read again when someone comes back.
    private func catchUp() async {
        models.leftovers.reconcileWithDisk()
        if let checked = models.leftovers.checkedAt, Date().timeIntervalSince(checked) > 30 * 60 {
            models.leftovers.markStale()
        }
        async let remnants: Void = showsRemnants ? models.leftovers.loadIfNeeded(service: service) : ()
        // Privacy entries are removed in System Settings, which is where
        // someone has just been when Brim becomes active again.
        async let background: Void = models.background.hasLoaded && [.background, .home].contains(shell.selection)
            ? models.background.load(service: service, applications: models.applications.applications) : ()
        async let updates: Void = shell.selection == .apps && shell.appsLens == .updates
            ? models.updates.loadIfNeeded(service: service) : ()
        async let space: Void = [.space, .home].contains(shell.selection)
            ? models.storage.readVolumes(service: service) : ()
        _ = await (remnants, background, updates, space)
    }
}

extension View {
    func keepsCurrent(_ models: SectionModels, shell: ShellState) -> some View {
        modifier(KeepsCurrent(models: models, shell: shell))
    }
}
