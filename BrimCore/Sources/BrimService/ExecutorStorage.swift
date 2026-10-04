import BrimCore
import BrimOps
import Foundation

extension Executor {
    nonisolated static func targetVolumes(for steps: [Step]) -> Set<String>? {
        var volumes = Set<String>()
        for step in steps where step.kind.targetIsPath {
            var information = statfs()
            let parent = URL(fileURLWithPath: step.target).deletingLastPathComponent().path
            guard statfs(parent, &information) == 0 else { return nil }
            let mount = withUnsafePointer(to: information.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            volumes.insert(mount)
        }
        return volumes.isEmpty ? nil : volumes
    }

    nonisolated static func sampleFreeSpace(
        on volumes: Set<String>, read: (String) throws -> Int64 = SafeOps.freeSpace(onPath:)
    ) -> Int64? {
        guard !volumes.isEmpty else { return nil }
        var total: Int64 = 0
        for volume in volumes {
            guard let sample = try? read(volume), sample >= 0 else { return nil }
            let addition = total.addingReportingOverflow(sample)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
}
