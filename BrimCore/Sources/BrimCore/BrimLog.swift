import os

/// Where Brim logs what it could not do: failures deliberately swallowed so
/// they cannot abort something the person asked for. Not for tracing.
/// `os.Logger` keeps interpolated strings private, which is right for paths;
/// never widen a path to `.public`. The administrator process has its own
/// logger, because `BrimPrivileged` depends on nothing.
public enum BrimLog {

    public static let subsystem = "com.sabharishhh.brim"

    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// Intervals for the waits a person feels, in Instruments' Points of
    /// Interest lane. They cost nothing unless a trace is recording.
    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
