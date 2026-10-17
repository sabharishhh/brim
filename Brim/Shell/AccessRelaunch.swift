import AppKit
import BrimUI
import os

/// Quits Brim and opens it again, for Full Disk Access that is switched on
/// but has not reached this process. The relaunch returns to the page that
/// asked (`FullDiskAccess.openSettings`). The script that reopens Brim waits
/// on a pipe Brim holds, never on a process identifier.
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

/// What a page that cannot read Library offers next: Open Settings until the
/// person has been sent there, then Reopen Brim while the request is fresh.
/// Read through `@AppStorage`, so a request on one page changes every page.
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
