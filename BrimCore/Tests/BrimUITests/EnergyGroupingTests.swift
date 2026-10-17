import XCTest
import BrimCore
@testable import BrimUI

/// One row per application, not per process: helpers resolve to the
/// outermost bundle.
@MainActor
final class EnergyGroupingTests: XCTestCase {

    private func measured(
        bundle: String?, executable: String,
        cpu: UInt64 = 0, wakeups: UInt64 = 0, bytes: UInt64 = 0, nanojoules: UInt64 = 1
    ) -> EnergyModel.Measured {
        EnergyModel.Measured(
            bundlePath: bundle, executablePath: executable,
            cpuNanoseconds: cpu, wakeups: wakeups, bytesMoved: bytes, nanojoules: nanojoules
        )
    }

    func testHelpersAreAddedIntoTheAppTheyBelongTo() {
        let chatGPT = "/Applications/ChatGPT.app"
        let rows = EnergyModel.group([
            measured(bundle: chatGPT, executable: "\(chatGPT)/Contents/MacOS/ChatGPT",
                     wakeups: 133, nanojoules: 133),
            measured(bundle: chatGPT, executable: "\(chatGPT)/Contents/Frameworks/Codex (Renderer)",
                     wakeups: 62, nanojoules: 62),
            measured(bundle: chatGPT, executable: "\(chatGPT)/Contents/Frameworks/Codex (Service)",
                     wakeups: 53, nanojoules: 53)
        ])

        XCTAssertEqual(rows.count, 1, "One app, one row")
        XCTAssertEqual(rows[0].name, "ChatGPT")
        XCTAssertEqual(rows[0].processCount, 3)
        XCTAssertEqual(rows[0].wakeups, 248, "The cost is the sum of every process")
        XCTAssertEqual(rows[0].nanojoules, 248)
    }

    func testDifferentAppsStayApart() {
        let rows = EnergyModel.group([
            measured(bundle: "/Applications/ChatGPT.app", executable: "a"),
            measured(bundle: "/Applications/Claude.app", executable: "b")
        ])
        XCTAssertEqual(Set(rows.map(\.name)), ["ChatGPT", "Claude"])
    }

    func testACommandLineToolIsNotFoldedIntoTheAppOfTheSameName() {
        // A terminal tool and an app that share a name stay apart; the tool has no
        // bundle.
        let rows = EnergyModel.group([
            measured(bundle: "/Applications/Claude.app", executable: "/Applications/Claude.app/Contents/MacOS/Claude"),
            measured(bundle: nil, executable: "/usr/local/bin/claude")
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter { $0.bundlePath == nil }.first?.name, "claude")
    }

    func testSeveralCopiesOfOneDaemonCollapseToo() {
        let rows = EnergyModel.group([
            measured(bundle: nil, executable: "/usr/libexec/somed", wakeups: 2, nanojoules: 2),
            measured(bundle: nil, executable: "/usr/libexec/somed", wakeups: 3, nanojoules: 3)
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].processCount, 2)
        XCTAssertEqual(rows[0].wakeups, 5)
    }

    func testTheBusiestAppLeads() {
        let rows = EnergyModel.group([
            measured(bundle: "/Applications/Quiet.app", executable: "q", nanojoules: 5),
            measured(bundle: "/Applications/Busy.app", executable: "b", nanojoules: 900)
        ])
        XCTAssertEqual(rows.map(\.name), ["Busy", "Quiet"])
    }
}

/// What the panel may show. macOS services busy on behalf of an app, such as
/// `powerd` holding sleep off while the display is on, are not listed beside
/// it: that is macOS working, and nobody can act on it.
@MainActor
final class EnergyScopeTests: XCTestCase {

    private func reading(
        _ path: String, bundle: String? = nil, nanojoules: UInt64 = 1_000_000_000
    ) -> EnergyModel.Reading {
        EnergyModel.Reading(
            identity: RunningProcessIdentity.of(bundlePath: bundle, executablePath: path),
            processCount: 1, cpuNanoseconds: 0, wakeups: 0, bytesMoved: 0,
            nanojoules: nanojoules
        )
    }

    func testServicesAndHelpersAreNotShownAtAll() {
        let hidden = [
            reading("/usr/libexec/trustd"),
            reading("/System/Library/PrivateFrameworks/X.framework/contactsd"),
            reading("/System/Library/CoreServices/powerd"),
            reading("/Applications/Claude.app/Contents/Frameworks/H.app/Contents/MacOS/H")
        ]
        for one in hidden {
            XCTAssertFalse(
                one.identity.kind.isActionable,
                "\(one.name) would be listed as something a person can act on"
            )
        }
    }

    /// An app Apple ships is still an app; the line is whether there is a window
    /// to quit.
    func testApplicationsAreShownWhoeverWroteThem() {
        let shown = [
            reading("/System/Applications/Music.app/Contents/MacOS/Music",
                    bundle: "/System/Applications/Music.app"),
            reading("/Applications/Claude.app/Contents/MacOS/Claude",
                    bundle: "/Applications/Claude.app"),
            reading("/opt/homebrew/bin/rg")
        ]
        for one in shown {
            XCTAssertTrue(one.identity.kind.isActionable, "\(one.name) should be listed")
        }
    }

    /// Wakeups decide the wording but are never printed: the figure alarms and
    /// nobody can act on it.
    func testWakeupsDecideTheWordingWithoutBeingShown() {
        let busy = EnergyModel.Reading(
            identity: RunningProcessIdentity.of(bundlePath: nil, executablePath: "/opt/homebrew/bin/x"),
            processCount: 1, cpuNanoseconds: 0, wakeups: 1331, bytesMoved: 0,
            nanojoules: 1_000_000_000
        )
        XCTAssertEqual(busy.dominantCost(over: 2).sentence, "Waking up often")

        // A few wakeups is not "often", or every row says the same thing.
        let quiet = EnergyModel.Reading(
            identity: RunningProcessIdentity.of(bundlePath: nil, executablePath: "/opt/homebrew/bin/y"),
            processCount: 1, cpuNanoseconds: 20_000_000, wakeups: 5, bytesMoved: 0,
            nanojoules: 1_000_000_000
        )
        XCTAssertEqual(quiet.dominantCost(over: 2).sentence, "Working steadily")
    }
}
