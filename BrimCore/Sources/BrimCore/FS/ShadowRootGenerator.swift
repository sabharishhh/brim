import Foundation

public struct ShadowRootGenerator: Sendable {
    public let sourceRoot: FileSystemRoot
    
    public init(sourceRoot: FileSystemRoot) {
        self.sourceRoot = sourceRoot
    }
    
    /// Creates a shadow root in a temporary directory and populates it with copies
    /// of the specified absolute file paths from the source root.
    public func createShadowRoot(copying paths: [String]) throws -> FileSystemRoot {
        let fm = FileManager.default
        let shadowDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: shadowDir, withIntermediateDirectories: true)
        
        for path in paths {
            let sourceURL = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: path) else { continue }
            
            // Reconstruct the full path structure inside the shadow root
            // Ensure path doesn't start with multiple slashes when appending
            let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let destURL = shadowDir.appendingPathComponent(relativePath)
            
            // Create parent directories
            let parentURL = destURL.deletingLastPathComponent()
            try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
            
            // Copy item
            try fm.copyItem(at: sourceURL, to: destURL)
        }
        
        return FileSystemRoot(rootURL: shadowDir)
    }
}
