import Foundation

public struct StorageAccountant: Sendable {
    
    public init() {}
    
    /// Evaluates the items in a footprint to determine the split between reclaimable and snapshot-pinned bytes.
    public func account(for items: [FootprintItem]) async -> (logical: Int64, reclaimable: Int64, pinned: Int64) {
        let logical = items.reduce(0) { $0 + $1.sizeBytes }
        
        let newestSnapshotDate = await getNewestSnapshotDate()
        
        var reclaimable: Int64 = 0
        var pinned: Int64 = 0
        
        let fm = FileManager.default
        
        for item in items {
            let path = item.evidence.url.path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let ctime = attrs[.creationDate] as? Date else {
                reclaimable += item.sizeBytes
                continue
            }
            
            let fileDate = max(mtime, ctime)
            
            if let snapDate = newestSnapshotDate, fileDate < snapDate {
                pinned += item.sizeBytes
            } else {
                reclaimable += item.sizeBytes
            }
        }
        
        return (logical, reclaimable, pinned)
    }
    
    private func getNewestSnapshotDate() async -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            
            let lines = output.split(separator: "\n")
            var newest: Date? = nil
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            
            for line in lines {
                // Expected format: com.apple.TimeMachine.2023-01-01-120000.local
                let parts = line.split(separator: ".")
                if parts.count >= 4, let dateStr = parts.dropLast().last {
                    if let date = formatter.date(from: String(dateStr)) {
                        if newest == nil || date > newest! {
                            newest = date
                        }
                    }
                }
            }
            
            return newest
        } catch {
            return nil
        }
    }
}
