import Foundation

/// Builds a deterministic synthetic filesystem tree for testing.
public struct FixtureTreeGenerator {
    public let rootURL: URL
    
    public init(rootURL: URL) {
        self.rootURL = rootURL
    }
    
    /// Generates the deterministic tree under `rootURL`.
    public func generate() throws {
        let fm = FileManager.default
        
        // Ensure root exists
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        
        // 1. Sandboxed App
        try createSandboxedApp(name: "SandboxedApp.app", bundleID: "com.brim.sandboxed")
        
        // 2. Non-Sandboxed App
        try createNonSandboxedApp(name: "ClassicApp.app", bundleID: "com.brim.classic")
        
        // 3. Pkg-installed product
        try createPkgInstalledProduct(receiptID: "com.brim.pkgproduct")
        
        // 4. Launch Daemons / Agents
        try createLaunchItems()
        
        // 5. Vendor folder claimed by two apps (Tier S)
        try createSharedVendorFolder(vendorName: "SharedVendor", claimants: ["com.brim.appA", "com.brim.appB"])
        
        // 6. Symlink pointing outside the tree (Race case)
        try createSymlinkOutsideTree()
        
        // 7. Item with immutable flag
        try createImmutableItem()
        
        // 8. Orphaned item
        try createOrphanedItem()
        
    // 9. App on a second "volume"
        try createSecondVolumeApp()
    }
    
    /// Cleans up the generated tree, including unsetting immutable flags so it can be deleted.
    public func destroy() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        process.arguments = ["-R", "nouchg", rootURL.path]
        try? process.run()
        process.waitUntilExit()
        
        try? FileManager.default.removeItem(at: rootURL)
    }
    
    // MARK: - Tree Generation Steps
    
    private func createSandboxedApp(name: String, bundleID: String) throws {
        let fm = FileManager.default
        let appURL = rootURL.appendingPathComponent("Applications/\(name)")
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        
        let plistData = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
        </dict>
        </plist>
        """.data(using: .utf8)!
        fm.createFile(atPath: appURL.appendingPathComponent("Contents/Info.plist").path, contents: plistData)
        
        let containerURL = rootURL.appendingPathComponent("Library/Containers/\(bundleID)")
        try fm.createDirectory(at: containerURL, withIntermediateDirectories: true)
        
        let groupContainerURL = rootURL.appendingPathComponent("Library/Group Containers/group.\(bundleID)")
        try fm.createDirectory(at: groupContainerURL, withIntermediateDirectories: true)
        
        // T-3.1 Additions
        let httpStorage = rootURL.appendingPathComponent("Library/HTTPStorages/\(bundleID)")
        try fm.createDirectory(at: httpStorage, withIntermediateDirectories: true)
        
        let lsDir = appURL.appendingPathComponent("Contents/Library/LaunchServices")
        try fm.createDirectory(at: lsDir, withIntermediateDirectories: true)
        fm.createFile(atPath: lsDir.appendingPathComponent("com.brim.helper").path, contents: Data("helper".utf8))
        
        let globalLD = rootURL.appendingPathComponent("Library/LaunchDaemons")
        try fm.createDirectory(at: globalLD, withIntermediateDirectories: true)
        let ldPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(bundleID).daemon</string>
            <key>Program</key>
            <string>\(appURL.path)/Contents/MacOS/\(name)</string>
        </dict>
        </plist>
        """
        fm.createFile(atPath: globalLD.appendingPathComponent("\(bundleID).daemon.plist").path, contents: Data(ldPlist.utf8))
    }
    
    private func createNonSandboxedApp(name: String, bundleID: String) throws {
        let fm = FileManager.default
        let appURL = rootURL.appendingPathComponent("Applications/\(name)")
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        
        let plistData = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
        </dict>
        </plist>
        """.data(using: .utf8)!
        fm.createFile(atPath: appURL.appendingPathComponent("Contents/Info.plist").path, contents: plistData)
        
        let appSupport = rootURL.appendingPathComponent("Library/Application Support/\(name)")
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        
        let prefs = rootURL.appendingPathComponent("Library/Preferences/\(bundleID).plist")
        try fm.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: prefs.path, contents: Data("dummy plist".utf8))
        
        // T-3.1 Additions
        let savedState = rootURL.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")
        try fm.createDirectory(at: savedState, withIntermediateDirectories: true)
        
        let caches = rootURL.appendingPathComponent("Library/Caches/\(bundleID)")
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        
        let teamIDGroup = rootURL.appendingPathComponent("Library/Group Containers/TEAMID1234.com.brim.classic")
        try fm.createDirectory(at: teamIDGroup, withIntermediateDirectories: true)
    }
    
    private func createPkgInstalledProduct(receiptID: String) throws {
        let fm = FileManager.default
        let receiptURL = rootURL.appendingPathComponent("Library/Receipts/\(receiptID).bom")
        try fm.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: receiptURL.path, contents: Data("dummy bom".utf8))
    }
    
    private func createLaunchItems() throws {
        let fm = FileManager.default
        let daemonURL = rootURL.appendingPathComponent("Library/LaunchDaemons/com.brim.daemon.plist")
        try fm.createDirectory(at: daemonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: daemonURL.path, contents: Data("dummy daemon".utf8))
    }
    
    private func createSharedVendorFolder(vendorName: String, claimants: [String]) throws {
        let fm = FileManager.default
        let vendorURL = rootURL.appendingPathComponent("Library/Application Support/\(vendorName)")
        try fm.createDirectory(at: vendorURL, withIntermediateDirectories: true)
        // Would also create claimants here
    }
    
    private func createSymlinkOutsideTree() throws {
        let fm = FileManager.default
        let symlinkURL = rootURL.appendingPathComponent("Library/Application Support/MaliciousSymlink")
        try fm.createDirectory(at: symlinkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
    }
    
    private func createImmutableItem() throws {
        let fm = FileManager.default
        let itemURL = rootURL.appendingPathComponent("Library/Application Support/ImmutableItem")
        try fm.createDirectory(at: itemURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: itemURL.path, contents: Data("immutable".utf8))
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        process.arguments = ["uchg", itemURL.path]
        try process.run()
        process.waitUntilExit()
    }
    
    private func createOrphanedItem() throws {
        let fm = FileManager.default
        let orphanURL = rootURL.appendingPathComponent("Library/Preferences/com.brim.orphan.plist")
        try fm.createDirectory(at: orphanURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: orphanURL.path, contents: Data("orphan".utf8))
    }
    
    private func createSecondVolumeApp() throws {
        let fm = FileManager.default
        let volumeURL = rootURL.appendingPathComponent("Volumes/Secondary/Applications/SecondVolumeApp.app")
        try fm.createDirectory(at: volumeURL, withIntermediateDirectories: true)
    }
}
