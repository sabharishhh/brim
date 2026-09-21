import XCTest
import BrimCore
@testable import BrimUI

/// One row per application, not per process.
///
/// The Energy list showed ChatGPT seven times and Claude three times,
/// because each is a crowd of processes: a renderer, a GPU helper, a crash
/// reporter, a network service, each with its own pid. The sampler was
/// right, it already resolves every helper back to the outermost bundle.
/// The list was simply showing what it was given.
@MainActor
final class EnergyGroupingTests: XCTestCase {

    private func measured(
        bundle: String?, executable: String,
        cpu: UInt64 = 0, wakeups: UInt64 = 0, bytes: UInt64 = 0, impact: UInt64 = 1
    ) -> EnergyModel.Measured {
        EnergyModel.Measured(
            bundlePath: bundle, executablePath: executable,
            cpuNanoseconds: cpu, wakeups: wakeups, bytesMoved: bytes, impact: impact
        )
    }

    func testHelpersAreAddedIntoTheAppTheyBelongTo() {
        let chatGPT = "/Applications/ChatGPT.app"
        let rows = EnergyModel.group([
            measured(bundle: chatGPT, executable: "\(chatGPT)/Contents/MacOS/ChatGPT",
                     wakeups: 133, impact: 133),
            measured(bundle: chatGPT, executable: "\(chatGPT)/Contents/Frameworks/Codex (Renderer)",
                     wakeups: 62, impact: 62),
            measured(bundle: chatGPT, executable: "\(chatGPT)/Contents/Frameworks/Codex (Service)",
                     wakeups: 53, impact: 53)
        ])

        XCTAssertEqual(rows.count, 1, "One app, one row")
        XCTAssertEqual(rows[0].name, "ChatGPT")
        XCTAssertEqual(rows[0].processCount, 3)
        XCTAssertEqual(rows[0].wakeups, 248, "The cost is the sum of every process")
        XCTAssertEqual(rows[0].impact, 248)
    }

    func testDifferentAppsStayApart() {
        let rows = EnergyModel.group([
            measured(bundle: "/Applications/ChatGPT.app", executable: "a"),
            measured(bundle: "/Applications/Claude.app", executable: "b")
        ])
        XCTAssertEqual(Set(rows.map(\.name)), ["ChatGPT", "Claude"])
    }

    func testACommandLineToolIsNotFoldedIntoTheAppOfTheSameName() {
        // `claude` the terminal tool and Claude.app are different programs
        // that happen to share a name. Grouping on the bundle keeps them
        // apart, and the tool has no bundle at all.
        let rows = EnergyModel.group([
            measured(bundle: "/Applications/Claude.app", executable: "/Applications/Claude.app/Contents/MacOS/Claude"),
            measured(bundle: nil, executable: "/usr/local/bin/claude")
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter { $0.bundlePath == nil }.first?.name, "claude")
    }

    func testSeveralCopiesOfOneDaemonCollapseToo() {
        let rows = EnergyModel.group([
            measured(bundle: nil, executable: "/usr/libexec/somed", wakeups: 2, impact: 2),
            measured(bundle: nil, executable: "/usr/libexec/somed", wakeups: 3, impact: 3)
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].processCount, 2)
        XCTAssertEqual(rows[0].wakeups, 5)
    }

    func testTheBusiestAppLeads() {
        let rows = EnergyModel.group([
            measured(bundle: "/Applications/Quiet.app", executable: "q", impact: 5),
            measured(bundle: "/Applications/Busy.app", executable: "b", impact: 900)
        ])
        XCTAssertEqual(rows.map(\.name), ["Busy", "Quiet"])
    }
}
