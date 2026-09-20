import Foundation

/// Defines rules for what files and directories are strictly forbidden from being removed.
public struct SafetyChecker: Sendable {
    public let root: FileSystemRoot
    
    // In a real scenario, this would be determined dynamically via Bundle.main, 
    // but we can inject it for testing.
    public let brimAppURL: URL
    
    public init(root: FileSystemRoot, brimAppURL: URL) {
        self.root = root
        self.brimAppURL = brimAppURL
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
        
        // 2. Protect /System
        if relativeComponents.first == "System" {
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
