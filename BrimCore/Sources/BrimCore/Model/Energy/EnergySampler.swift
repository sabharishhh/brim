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

    /// Energy the process has used since it started, in nanojoules, from
    /// `ri_energy_nj`.
    public let energyNanojoules: UInt64
    /// The part spent on performance cores, from `ri_penergy_nj`. The same work
    /// costs several times more there.
    public let performanceCoreNanojoules: UInt64
    /// When the process started, in Mach absolute time. A pid can be reused, so
    /// accumulating without this would credit one process's energy to another.
    public let startedAt: UInt64

    /// Joules, for arithmetic that has to read as arithmetic.
    public var joules: Double { Double(energyNanojoules) / 1_000_000_000 }

    /// Milliwatt-hours, what a battery is measured in. 1 Wh is 3600 J.
    public var milliwattHours: Double { joules / 3.6 }

    public init(
        pid: Int32, executablePath: String, bundlePath: String?,
        userTime: UInt64, systemTime: UInt64,
        diskReadBytes: UInt64, diskWriteBytes: UInt64, wakeups: UInt64,
        energyNanojoules: UInt64 = 0, performanceCoreNanojoules: UInt64 = 0,
        startedAt: UInt64 = 0
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.bundlePath = bundlePath
        self.userTime = userTime
        self.systemTime = systemTime
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.wakeups = wakeups
        self.energyNanojoules = energyNanojoules
        self.performanceCoreNanojoules = performanceCoreNanojoules
        self.startedAt = startedAt
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
            // A process whose path cannot be read is a gap, not a row: energy that
            // cannot be attributed is counted as a gap, never listed as "unknown".
            guard pathRet > 0 else {
                gaps += 1
                continue
            }
            let path = pathBuffer.withUnsafeBufferPointer { ptr in
                let u8ptr = ptr.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: Int(pathRet)) { $0 }
                return String(decoding: UnsafeBufferPointer(start: u8ptr, count: Int(pathRet)), as: UTF8.self)
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
                    wakeups: ru.ri_interrupt_wkups + ru.ri_pkg_idle_wkups,
                    energyNanojoules: ru.ri_energy_nj,
                    performanceCoreNanojoules: ru.ri_penergy_nj,
                    startedAt: ru.ri_proc_start_abstime
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
