import Foundation
import ArgumentParser
import BrimCore
import ServiceManagement

struct EnergyCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "energy", abstract: "Interact with the Brim Energy Sampler")

    /// What the energy agent is called.
    ///
    /// This used to be one of the two historical identifiers, which are kept
    /// only so an upgrade can clear what they left behind. Registering *new*
    /// work under one of them meant `brim energy --register` installed a
    /// launch agent, with RunAtLoad and KeepAlive set, under a name that is
    /// not Brim's. A utility that exists to find background agents nobody
    /// can account for cannot be installing one.
    static let agentLabel = "com.sabharishhh.brim.energy"

    /// The name earlier builds registered under. Kept so `--unregister`
    /// clears an agent installed before the rename, which is the only reason
    /// either old identifier is allowed to appear anywhere.
    static let formerAgentLabel = "com.google.Brim.energy"
    
    @Flag(name: [.customShort("r"), .long], help: "Register the energy sampling background agent")
    var register = false
    
    @Flag(name: [.customShort("u"), .long], help: "Unregister the energy sampling background agent")
    var unregister = false
    
    @Flag(name: .long, help: "Run the background agent directly")
    var runAgent = false
    
    mutating func run() async throws {
        if register {
            var registeredViaSMAppService = false
            if #available(macOS 13.0, *) {
                let service = SMAppService.agent(plistName: "\(Self.agentLabel).plist")
                do {
                    try service.register()
                    registeredViaSMAppService = true
                    print("Energy agent registered via SMAppService.")
                } catch {
                    // Fallback for standalone CLI executions outside an app bundle
                }
            }
            if !registeredViaSMAppService {
                let fm = FileManager.default
                let userAgentsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
                try? fm.createDirectory(at: userAgentsDir, withIntermediateDirectories: true)
                let destPlist = userAgentsDir.appendingPathComponent("\(Self.agentLabel).plist")
                
                let currentExec = Bundle.main.executablePath ?? CommandLine.arguments[0]
                let plistContent = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key>
                    <string>\(Self.agentLabel)</string>
                    <key>ProgramArguments</key>
                    <array>
                        <string>\(currentExec)</string>
                        <string>energy</string>
                        <string>--run-agent</string>
                    </array>
                    <key>RunAtLoad</key>
                    <true/>
                    <key>KeepAlive</key>
                    <true/>
                </dict>
                </plist>
                """
                try plistContent.write(to: destPlist, atomically: true, encoding: .utf8)
                print("Energy agent registered to \(destPlist.path).")
            }
        } else if unregister {
            if #available(macOS 13.0, *) {
                let service = SMAppService.agent(plistName: "\(Self.agentLabel).plist")
                try? await service.unregister()
            }
            let fm = FileManager.default
            let agents = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents")
            // Both names. Anyone who registered before the rename has an
            // agent on disk under the old one, and leaving it there would be
            // Brim producing exactly the orphan it reports on.
            for label in [Self.agentLabel, Self.formerAgentLabel] {
                let plist = agents.appendingPathComponent("\(label).plist")
                if fm.fileExists(atPath: plist.path) {
                    try? fm.removeItem(at: plist)
                }
            }
            print("Energy agent unregistered.")
        } else if runAgent {
            print("Running energy agent loop...")
            let sampler = EnergySampler()
            let fileURL = URL(fileURLWithPath: "/tmp/brim_energy_deltas.json")
            
            // 1. Load existing cumulative scores from disk to accumulate across agent restarts
            var cumulativeScores: [String: UInt64] = [:]
            if let existingData = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode([String: UInt64].self, from: existingData) {
                cumulativeScores = decoded
            }
            
            // In-memory baseline tracking per PID to calculate deltas
            var lastObservedScores: [pid_t: UInt64] = [:]
            
            while true {
                let result = await sampler.sample()
                var currentPids = Set<pid_t>()
                
                for s in result.samples {
                    currentPids.insert(s.pid)
                    let key = s.bundlePath ?? s.executablePath
                    let currentScore = s.energyNanojoules
                    let previousScore = lastObservedScores[s.pid] ?? 0
                    
                    let delta: UInt64
                    if currentScore >= previousScore {
                        delta = currentScore - previousScore
                    } else {
                        // PID wrap-around or process restart
                        delta = currentScore
                    }
                    
                    lastObservedScores[s.pid] = currentScore
                    cumulativeScores[key, default: 0] += delta
                }
                
                // Evict terminated PIDs from baseline tracking
                lastObservedScores = lastObservedScores.filter { currentPids.contains($0.key) }
                
                // Persist cumulative usage so process terminations never wipe history
                if let data = try? JSONEncoder().encode(cumulativeScores) {
                    try? data.write(to: fileURL)
                }
                
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        } else {
            // Sample once and print
            let sampler = EnergySampler()
            let result = await sampler.sample()
            
            var aggregated: [String: UInt64] = [:]
            for s in result.samples {
                let key = s.bundlePath ?? s.executablePath
                aggregated[key, default: 0] += s.energyNanojoules
            }
            
            let battery = BatteryCapacity.current()
            // Printed only when there is something to say. It used to print
            // unconditionally, so a complete reading opened with "0 processes
            // could not be read, so this list is short by that much."
            if result.coverageGaps > 0 {
                print("Not counting \(result.coverageGaps) processes owned by the system, "
                      + "whose energy macOS reports only to their own user.")
            }
            for (path, nanojoules) in aggregated.sorted(by: { $0.value > $1.value }).prefix(20) {
                let milliwattHours = Double(nanojoules) / 1_000_000_000 / 3.6
                let share = battery?.sentence(forMilliwattHours: milliwattHours)
                print(String(format: "%8.1f mWh", milliwattHours)
                      + (share.map { "  (\($0))" } ?? "")
                      + "  \(path)")
            }
        }
    }
}
