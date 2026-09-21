import Foundation
import Darwin

public struct EnergySample: Codable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public let bundlePath: String? // nil if not inside an app bundle
    public let userTime: UInt64
    public let systemTime: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let wakeups: UInt64
    
    // A synthetic impact score combining CPU time, disk IO, and wakeups.
    // Explicitly not physical Joules.
    public var impactScore: UInt64 {
        // CPU time in ns (1e9 ns = 1s). Wakeups and IO also cost energy.
        // Synthetic metric for spike.
        return userTime + systemTime + (wakeups * 1000_000) + (diskReadBytes + diskWriteBytes) * 10
    }
    
    @available(*, deprecated, message: "Use impactScore instead; this metric is a synthetic score, not physical energy.")
    public var energyScore: UInt64 {
        return impactScore
    }
}

public struct EnergySampleResult: Codable, Sendable {
    public let samples: [EnergySample]
    /// Processes that could not be read at all, so a short list is never
    /// mistaken for a quiet machine.
    public let coverageGaps: Int

    public init(samples: [EnergySample], coverageGaps: Int) {
        self.samples = samples
        self.coverageGaps = coverageGaps
    }
}

public actor EnergySampler {
    public init() {}
    
    public func sample() -> EnergySampleResult {
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return EnergySampleResult(samples: [], coverageGaps: 0) }
        
        var pids = [pid_t](repeating: 0, count: Int(count)/MemoryLayout<pid_t>.stride + 10)
        count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        
        let actualCount = Int(count) / MemoryLayout<pid_t>.stride
        
        var samples = [EnergySample]()
        var gaps = 0
        
        for i in 0..<actualCount {
            let pid = pids[i]
            if pid <= 0 { continue }
            
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let pathRet = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path: String
            if pathRet > 0 {
                path = pathBuffer.withUnsafeBufferPointer { ptr in
                    let u8ptr = ptr.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: Int(pathRet)) { $0 }
                    return String(decoding: UnsafeBufferPointer(start: u8ptr, count: Int(pathRet)), as: UTF8.self)
                }
            } else {
                path = "unknown"
            }
            
            var ru = rusage_info_v6()
            let ret = withUnsafeMutablePointer(to: &ru) { ptr in
                return ptr.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) { reboundPtr in
                    return proc_pid_rusage(pid, RUSAGE_INFO_V6, reboundPtr)
                }
            }
            
            if ret == 0 {
                let bundlePath = extractBundlePath(from: path)
                let sample = EnergySample(
                    pid: pid,
                    executablePath: path,
                    bundlePath: bundlePath,
                    userTime: ru.ri_user_time,
                    systemTime: ru.ri_system_time,
                    diskReadBytes: ru.ri_diskio_bytesread,
                    diskWriteBytes: ru.ri_diskio_byteswritten,
                    wakeups: ru.ri_interrupt_wkups + ru.ri_pkg_idle_wkups
                )
                samples.append(sample)
            } else {
                gaps += 1
            }
        }
        return EnergySampleResult(samples: samples, coverageGaps: gaps)
    }
    
    private func extractBundlePath(from execPath: String) -> String? {
        // e.g. /Applications/Safari.app/Contents/MacOS/Safari
        if let range = execPath.range(of: ".app/Contents/") {
            return String(execPath[..<range.lowerBound]) + ".app"
        }
        return nil
    }
}
