import Foundation
import ArgumentParser
import BrimCore
import ServiceManagement

struct EnergyCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "energy", abstract: "Interact with the Brim Energy Sampler")
    
    @Flag(name: .shortAndLong, help: "Register the energy sampling background agent")
    var register = false
    
    @Flag(name: .shortAndLong, help: "Unregister the energy sampling background agent")
    var unregister = false
    
    @Flag(name: .shortAndLong, help: "Run the background agent directly")
    var runAgent = false
    
    mutating func run() async throws {
        if register {
            if #available(macOS 13.0, *) {
                let service = SMAppService.agent(plistName: "com.google.Brim.energy.plist")
                try service.register()
                print("Energy agent registered.")
            } else {
                print("SMAppService requires macOS 13+")
            }
        } else if unregister {
            if #available(macOS 13.0, *) {
                let service = SMAppService.agent(plistName: "com.google.Brim.energy.plist")
                try await service.unregister()
                print("Energy agent unregistered.")
            } else {
                print("SMAppService requires macOS 13+")
            }
        } else if runAgent {
            print("Running energy agent loop...")
            let sampler = EnergySampler()
            while true {
                let result = await sampler.sample()
                var aggregated: [String: UInt64] = [:]
                for s in result.samples {
                    let key = s.bundlePath ?? s.executablePath
                    aggregated[key, default: 0] += s.energyScore
                }
                
                // Write out deltas
                let fileURL = URL(fileURLWithPath: "/tmp/brim_energy_deltas.json")
                if let data = try? JSONEncoder().encode(aggregated) {
                    try? data.write(to: fileURL)
                }
                
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        } else {
            // Just sample once and print
            let sampler = EnergySampler()
            let result = await sampler.sample()
            
            var aggregated: [String: UInt64] = [:]
            for s in result.samples {
                let key = s.bundlePath ?? s.executablePath
                aggregated[key, default: 0] += s.energyScore
            }
            
            print("Coverage Gaps (Root-owned restricted): \(result.coverageGaps) processes hidden.")
            for (path, score) in aggregated.sorted(by: { $0.value > $1.value }).prefix(20) {
                print("\(score) J - \(path)")
            }
        }
    }
}
