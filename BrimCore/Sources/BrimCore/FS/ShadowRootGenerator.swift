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
            
            // Copy item safely without traversing symlinks
            var statBuf = stat()
            if lstat(path, &statBuf) == 0 {
                let mode = statBuf.st_mode
                if (mode & S_IFMT) == S_IFLNK {
                    let destination = try fm.destinationOfSymbolicLink(atPath: path)
                    try fm.createSymbolicLink(atPath: destURL.path, withDestinationPath: destination)
                } else if (mode & S_IFMT) == S_IFDIR {
                    try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                } else {
                    let data = try Data(contentsOf: sourceURL)
                    try data.write(to: destURL)
                }
            }
        }
        
        return FileSystemRoot(rootURL: shadowDir)
    }
}
