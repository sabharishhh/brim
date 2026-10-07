import AppKit
import BrimUI
import os

/// Quits Brim and opens it again, for Full Disk Access that has been
/// switched on but has not reached this process.
///
/// macOS offers Quit and Reopen when Brim is switched on in System Settings,
/// and also Later. After Later, Brim kept saying Library could not be read
/// and offered Open Settings again, which only showed a switch that was
/// already on. Now it offers to reopen itself, and comes back where the
/// person was: the request `FullDiskAccess.openSettings` remembered tells
/// the next launch to return to the same page, and to the Settings window
/// when that is where it was asked from.
///
/// The new Brim is started by a short script that waits for this one to
/// quit. It waits on a pipe Brim holds, which closes when Brim's process
/// ends, never on a process identifier, the same way `SelfRemoval` does.
@MainActor
enum AccessRelaunch {
    private static let log = Logger(subsystem: "com.sabharishhh.brim", category: "relaunch")
    private static var lifeline: Pipe?

    static func reopen() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/bin/cat > /dev/null; exec /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("could not arrange the reopen: \(error.localizedDescription)")
            return
        }
        lifeline = pipe
        Task {
            await QuitRequest.shared.quit()
            // Still running, so the script must not open a second Brim the
            // next time this one quits.
            log.error("quit was refused; the reopen is cancelled")
            process.terminate()
        }
    }
}

/// What a place that cannot read Library offers next.
///
/// Open Settings until the person has been sent there, then Reopen Brim
/// for as long as the request is fresh: by then the switch is usually on,
/// and showing it again does nothing. Read through `@AppStorage` on
/// `FullDiskAccess.requestedKey`, so a request made on one page changes
/// the offer on every page.
struct AccessOffer {
    let title: String
    let action: () -> Void

    @MainActor
    static func current(requestedAt: Double, from origin: FullDiskAccess.Origin = .window) -> AccessOffer {
        if FullDiskAccess.isRecent(requestedAt) {
            return AccessOffer(title: "Reopen Brim") { AccessRelaunch.reopen() }
        }
        return AccessOffer(title: "Open Settings") { FullDiskAccess.openSettings(from: origin) }
    }
}
