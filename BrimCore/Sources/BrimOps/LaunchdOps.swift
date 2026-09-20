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
        
        // It's acceptable for unload to fail if it was already unloaded, but we log it.
        // Actually, launchctl bootout might be better, but unload works universally.
        if task.terminationStatus != 0 {
            // Read output to log or debug
            // let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // let output = String(data: data, encoding: .utf8)
            // print("Unload failed: \(output ?? "")")
        }
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
