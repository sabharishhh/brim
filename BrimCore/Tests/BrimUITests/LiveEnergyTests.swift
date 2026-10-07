import BrimCore
import BrimProtocol
@testable import BrimUI
import Foundation
import Testing

/// Energy took one reading and then never changed until someone pressed a
/// button. It now follows the Mac while the page is on screen, and reads
/// nothing while Brim cannot be seen.
@MainActor struct LiveEnergyTests {
    @Test func `the apps' draw keeps updating while the page is shown`() async {
        let service = Counters()
        let model = EnergyModel(gap: .milliseconds(5), tick: .milliseconds(5))
        let following = Task { await model.follow(service: service, visible: { true }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await service.calls < 5, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        following.cancel()
        await following.value
        #expect(await service.calls >= 5)
        #expect(model.applications.map(\.identity.groupKey) == ["/Applications/Demo.app"])
        #expect(!model.isSampling)
    }

    @Test func `nothing is sampled while Brim cannot be seen`() async {
        let service = Counters()
        let model = EnergyModel(gap: .milliseconds(5), tick: .milliseconds(5))
        let following = Task { await model.follow(service: service, visible: { false }) }
        try? await Task.sleep(for: .milliseconds(100))
        following.cancel()
        await following.value
        #expect(await service.calls == 0)
    }
}

/// An app whose energy counter climbs by 0.1 J between samples.
private actor Counters: BrimServiceProtocol {
    private(set) var calls = 0

    func sampleEnergy() async -> EnergySampleResult {
        calls += 1
        let sample = EnergySample(
            pid: 42, executablePath: "/Applications/Demo.app/Contents/MacOS/Demo",
            bundlePath: "/Applications/Demo.app", userTime: UInt64(calls) * 1_000_000, systemTime: 0,
            diskReadBytes: 0, diskWriteBytes: 0, wakeups: 0, energyNanojoules: UInt64(calls) * 100_000_000
        )
        return EnergySampleResult(samples: [sample], coverageGaps: 0)
    }

    func leftovers() async throws -> [Leftover] {
        []
    }

    func installedApplications() async throws -> [InstalledApplication] {
        []
    }

    func recoverableItems() async throws -> [RecoverableItem] {
        []
    }

    func history() async throws -> [Plan] {
        []
    }

    func inspect(identity _: Identity) async throws -> Footprint {
        throw Unused.unused
    }

    func plan(intent _: PlanIntent) async throws -> Plan {
        throw Unused.unused
    }

    func requestApproval(planId _: UUID, requesterIdentity _: String) async throws -> ApprovalRequestReceipt {
        throw Unused.unused
    }

    func apply(planId _: UUID, token _: ApprovalToken) async throws {
        throw Unused.unused
    }

    func verify(planId _: UUID) async throws -> VerificationResult {
        throw Unused.unused
    }

    func undo(planId _: UUID) async throws {
        throw Unused.unused
    }
}

private enum Unused: Error { case unused }
