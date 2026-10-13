import Foundation

/// Defines rules for what files and directories are strictly forbidden from being removed.
public struct SafetyChecker: Sendable {
    public let root: FileSystemRoot
    
    // Injected rather than read from Bundle.main, so a fixture tree can
    // have its own Brim to protect.
    public let brimAppURL: URL

    /// Brim's own bundle identifier, read from the bundle this checker was
    /// given. Derived rather than listed, because the list was wrong: it
    /// named `com.google.Brim` and a `devplaceholder` identifier, and the
    /// application ships as `com.sabharishhh.brim`, so nothing matched and
    /// Brim could not uninstall itself at all.
    public let brimBundleID: String?

    public init(root: FileSystemRoot, brimAppURL: URL) {
        self.root = root
        self.brimAppURL = brimAppURL
        self.brimBundleID = Self.bundleIdentifier(at: brimAppURL)
    }

    /// Whether this identity is the Brim that is running.
    ///
    /// Self-removal is the one case where Brim's own files may be touched,
    /// so getting this wrong in one direction blocks "Uninstall Brim" and
    /// in the other lets any application claiming Brim's identifier reach
    /// them. It compares against the bundle on disk, and falls back to the
    /// identifiers older builds shipped under so an upgrade can still
    /// remove what they left.
    public func isBrimItself(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if let brimBundleID, bundleID == brimBundleID { return true }
        return Self.identifiersOlderBuildsUsed.contains(bundleID)
    }

    /// Only for finding what a previous Brim left behind. Never widened:
    /// each one here is an identifier this project genuinely shipped.
    public static let identifiersOlderBuildsUsed: Set<String> = [
        "devplaceholder.PJ52YXEB.brim",
        "com.google.Brim",
    ]

    private static func bundleIdentifier(at bundleURL: URL) -> String? {
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }
        return parsed["CFBundleIdentifier"] as? String
    }
    
    /// Evaluates if a given URL is safe to remove.
    public func isSafeToRemove(url: URL, isSelfRemoval: Bool = false) -> Bool {
        // 1. Cannot remove outside the FileSystemRoot (for synthetic tree testing)
        let rootComponents = root.rootURL.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.resolvingSymlinksInPath().pathComponents
        
        guard urlComponents.count >= rootComponents.count,
              Array(urlComponents.prefix(rootComponents.count)) == rootComponents else {
            return false
        }
        
        // Get the relative components
        let relativeComponents = Array(urlComponents.dropFirst(rootComponents.count))
        
        // The BTM archive holds many applications' records. It is never
        // an app-owned file, even when a record attributes one of its entries.
        let protectedStores = [["var", "db", "com.apple.backgroundtaskmanagement"],
                               ["private", "var", "db", "com.apple.backgroundtaskmanagement"]]
        if protectedStores.contains(where: { store in
            let sharedCount = min(store.count, relativeComponents.count)
            return Array(store.prefix(sharedCount)) == Array(relativeComponents.prefix(sharedCount))
        }) {
            return false
        }

        // 2. Protect /System
        if relativeComponents.first == "System" {
            return false
        }

        // Never the person's own folders, nor where credentials are kept,
        // whatever claims them. An app's product.json may name any dot
        // folder in the home folder as its data, and a declaration is Tier B,
        // which is ticked: one naming `.ssh` had the person's keys selected
        // for removal with it.
        if Self.isPersonal(relativeComponents, userName: root.userName) {
            return false
        }
        
        // 3. Protect iCloud Drive (Mobile Documents)
        if let libIndex = relativeComponents.firstIndex(of: "Library"), 
           libIndex + 1 < relativeComponents.count, 
           relativeComponents[libIndex + 1] == "Mobile Documents" {
            return false
        }
        
        // 4. Protect the Brim App itself
        let brimComponents = brimAppURL.resolvingSymlinksInPath().pathComponents
        let isBrimSubdir = urlComponents.count >= brimComponents.count && Array(urlComponents.prefix(brimComponents.count)) == brimComponents
        let isBrimParent = brimComponents.count >= urlComponents.count && Array(brimComponents.prefix(urlComponents.count)) == urlComponents
        
        if !isSelfRemoval && (isBrimSubdir || isBrimParent) {
            return false
        }
        
        // 5. Protect files with the immutable flag
        if isImmutable(url: url) {
            return false
        }
        
        return true
    }
    
    /// Folders that hold what the person made or uses to prove who they
    /// are. The folder itself is never taken; for credential stores, nothing
    /// inside it is either.
    static let personalFolders: Set<String> = [
        "desktop", "documents", "downloads", "movies", "music", "pictures", "public", "applications",
        "library", "developer", ".config", ".local", ".cache", ".trash"
    ]
    static let credentialStores: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".password-store", ".netrc", ".pgpass",
        ".git-credentials", ".gitconfig", ".npmrc", ".pypirc", ".zshrc", ".zprofile", ".bashrc",
        ".bash_profile", ".profile"
    ]
    static let topLevelFolders: Set<String> = [
        "applications", "library", "users", "system", "private", "usr", "opt", "volumes", "cores"
    ]
    /// Inside Library: the folders every app shares, and the keychains.
    static let sharedLibraryFolders: Set<String> = [
        "application support", "caches", "preferences", "containers", "group containers", "logs",
        "launchagents", "httpstorages", "webkit", "saved application state", "cookies", "mobile documents"
    ]

    static func isPersonal(_ components: [String], userName: String) -> Bool {
        let lowered = components.map { $0.lowercased() }
        // The root of the disk and its main folders, Users, Users/Shared,
        // and every home folder.
        if lowered.isEmpty || (lowered.count == 1 && topLevelFolders.contains(lowered[0]))
            || (lowered.count == 2 && lowered[0] == "users") {
            return true
        }
        guard lowered.count >= 3, lowered[0] == "users", lowered[1] == userName.lowercased() else {
            return false
        }
        let first = lowered[2]
        if credentialStores.contains(first) {
            return true
        }
        if lowered.count == 3, personalFolders.contains(first) {
            return true
        }
        if first == "library", lowered.count >= 4 {
            if lowered[3] == "keychains" {
                return true
            }
            return lowered.count == 4 && sharedLibraryFolders.contains(lowered[3])
        }
        return false
    }

    private func isImmutable(url: URL) -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let isImmutable = attributes[.immutable] as? Bool {
                return isImmutable
            }
        } catch {
            // If the file does not exist, it isn't immutable.
            return false
        }
        return false
    }
}
