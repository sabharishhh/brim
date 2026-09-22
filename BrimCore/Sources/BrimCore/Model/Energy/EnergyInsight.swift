import Foundation

/// What a reading means, as facts rather than as prose.
///
/// Built for two readers at once. The panel renders it deterministically
/// today, and `T-7.6` hands the same values to the on-device model to say in
/// plain language. That is the whole reason it is a structure and not a
/// string: every field here is something Brim measured, so a sentence built
/// from it restates a computed fact and asserts nothing new, which is the
/// line `C-5` actually draws.
///
/// Nothing in here projects forward. How long a battery lasts depends on
/// what the machine does next, and a figure in minutes reads as a promise.
public struct EnergyInsight: Sendable, Equatable {

    /// How the reading was taken, so a sentence can say so.
    public let windowSeconds: Double
    /// Total draw attributed across everything measured, in milliwatts.
    public let totalMilliwatts: Double
    /// The share of that drawn by things the person launched.
    public let yoursMilliwatts: Double
    /// The share drawn by macOS running itself.
    public let systemMilliwatts: Double

    /// The busiest thing, and why it is busiest.
    public let busiestName: String?
    public let busiestMilliwatts: Double
    public let busiestIsSystem: Bool
    public let busiestBehaviour: String?
    /// Whether the busiest thing is Brim itself.
    ///
    /// Taking the reading costs something, and on a quiet Mac that cost can
    /// be the largest single figure in it. Seen on this machine: Brim read
    /// 3392 mW for itself immediately after a scan, eight times the whole
    /// machine's plausible draw, and the honest explanation is that the
    /// measurement was measuring the measurement. Saying so is better than
    /// hiding the row, which would make the totals stop adding up.
    public let busiestIsBrimItself: Bool

    /// How many processes could not be read, and why that is expected.
    public let unreadableProcesses: Int

    /// What a full charge holds, when this Mac has a battery.
    public let batteryMilliwattHours: Double?

    public init(
        windowSeconds: Double,
        totalMilliwatts: Double,
        yoursMilliwatts: Double,
        systemMilliwatts: Double,
        busiestName: String?,
        busiestMilliwatts: Double,
        busiestIsSystem: Bool,
        busiestBehaviour: String?,
        busiestIsBrimItself: Bool = false,
        unreadableProcesses: Int,
        batteryMilliwattHours: Double?
    ) {
        self.windowSeconds = windowSeconds
        self.totalMilliwatts = totalMilliwatts
        self.yoursMilliwatts = yoursMilliwatts
        self.systemMilliwatts = systemMilliwatts
        self.busiestName = busiestName
        self.busiestMilliwatts = busiestMilliwatts
        self.busiestIsSystem = busiestIsSystem
        self.busiestBehaviour = busiestBehaviour
        self.busiestIsBrimItself = busiestIsBrimItself
        self.unreadableProcesses = unreadableProcesses
        self.batteryMilliwattHours = batteryMilliwattHours
    }

    /// What share of the measured draw is macOS rather than the person's
    /// own software. The most useful single number in the panel, because it
    /// answers "is this me or is this the Mac".
    public var systemShare: Double {
        guard totalMilliwatts > 0 else { return 0 }
        return systemMilliwatts / totalMilliwatts
    }

    /// The deterministic sentence, which is the floor the model improves on
    /// and the text shown whenever the model is unavailable.
    ///
    /// Written to be true of an idle Mac as well as a busy one, because the
    /// common case for this panel is that nothing much is happening and
    /// saying so plainly is more use than a list of near-zero rows.
    public var sentence: String {
        guard totalMilliwatts > 0, let busiestName else {
            return "Nothing drew enough power to measure over the last "
                 + "\(Self.seconds(windowSeconds))."
        }

        if busiestIsBrimItself {
            return "Brim itself is the busiest thing in this reading, which is what taking the "
                 + "reading costs. Sample again once it has settled to see the rest."
        }

        var parts: [String] = []

        if busiestIsSystem {
            parts.append("Most of the draw right now is macOS itself, led by \(busiestName)")
        } else {
            parts.append("\(busiestName) is drawing the most right now")
        }

        if let behaviour = busiestBehaviour {
            parts.append(behaviour.lowercased())
        }

        var text = parts.joined(separator: ", ") + "."

        if systemShare >= 0.5 && !busiestIsSystem {
            text += " macOS accounts for "
                 + "\(Int((systemShare * 100).rounded()))% of what was measured."
        } else if systemShare < 0.5 && busiestIsSystem {
            text += " Your own software accounts for the rest."
        }

        return text
    }

    /// Why a count of unreadable processes is not a gap in the product.
    ///
    /// macOS reports a process's energy only to something running as that
    /// process's user, so a Mac's root daemons are invisible to every
    /// user-level tool, Brim included. Saying the number without the reason
    /// reads as a failure; the reason is what makes it a fact.
    public var coverageSentence: String? {
        guard unreadableProcesses > 0 else { return nil }
        return "\(unreadableProcesses) processes run as the system, and macOS reports their "
             + "energy only to the system. They are not in these figures."
    }

    private static func seconds(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded == 1 ? "second" : "\(rounded) seconds"
    }
}
