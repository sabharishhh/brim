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
    public func isSafeToRemove(url: URL) -> Bool {
        // 1. Cannot remove outside the FileSystemRoot (for synthetic tree testing)
        // If the url does not have the root prefix, it's unsafe.
        guard url.path.hasPrefix(root.rootURL.path) else {
            return false
        }
        
        let relativePath = url.path.replacingOccurrences(of: root.rootURL.path, with: "")
        
        // 2. Protect /System
        if relativePath.hasPrefix("/System") || relativePath == "/System" {
            return false
        }
        
        // 3. Protect iCloud Drive (Mobile Documents)
        // A naive check: contains /Library/Mobile Documents
        if relativePath.contains("/Library/Mobile Documents") {
            return false
        }
        
        // 4. Protect the Brim App itself
        if url.path.hasPrefix(brimAppURL.path) || brimAppURL.path.hasPrefix(url.path) {
            // Note: `brimAppURL.path.hasPrefix(url.path)` prevents removing a parent directory of Brim.
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
