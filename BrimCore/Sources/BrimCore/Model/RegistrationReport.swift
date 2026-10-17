import Foundation

/// What macOS holds on behalf of software, and how much of it Brim managed
/// to read. Coverage travels with the registrations, so "did not look" and
/// "nothing there" are never shown the same way.
public struct RegistrationReport: Sendable, Codable, Equatable {
    public let registrations: [Registration]
    public let coverage: [RegistrationCoverage]

    public init(registrations: [Registration], coverage: [RegistrationCoverage]) {
        self.registrations = registrations
        self.coverage = coverage
    }

    public static let empty = RegistrationReport(registrations: [], coverage: [])

    /// Entries pointing at a program that is no longer on disk, and that the
    /// user could actually do something about.
    public var stale: [Registration] {
        registrations.filter(\.isActionableStale)
    }

    /// Entries that still point at something real.
    public var live: [Registration] {
        registrations.filter { !$0.isStale || !$0.isActionable }
    }

    /// Surfaces that could not be read, so the view can say so.
    public var gaps: [RegistrationCoverage] {
        coverage.filter { !$0.available }
    }
}
