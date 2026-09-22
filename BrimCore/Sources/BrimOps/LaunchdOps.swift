import Foundation

extension SafeOps {
    public static func unloadLaunchdJob(path: String) throws {
        // Run launchctl unload. In a real uninstaller, we might use SMAppService.daemon(plistName:).unregister()
        // if we are the app itself, but since we are an external uninstaller, we use launchctl.
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["unload", path]
        
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        
        try task.run()
        task.waitUntilExit()
        
        // A non-zero status is ignored on purpose: a job that was already
        // unloaded is the common case and is not a failure. The comment here
        // used to say "we log it", above an empty branch holding a
        // commented-out `print`, which said nothing was logged at all. It is
        // still nothing, and now it says so. Whether a genuine unload failure
        // should reach the journal is a real question, and a separate one
        // from removing debug output: launchd keeping a job alive after its
        // plist is gone is the B2 failure mode in `docs/deep-uninstall.md`.
    }
    public static func loadLaunchdJob(path: String) throws {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["load", path]
        
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        
        try task.run()
        task.waitUntilExit()
    }
}
