import BrimCore
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// A place macOS records that an application exists, other than the file
/// system. One surface per mechanism, like `EvidenceSource`, serving both
/// questions: what belongs to this app, and what belongs to nothing.
public protocol RegistrationSurface: Sendable {
    var kind: Registration.Kind { get }

    /// Everything this mechanism holds. Empty rather than throwing when
    /// unavailable; `coverage` says why.
    func registrations(in root: FileSystemRoot) async -> [Registration]

    /// Whether this surface could be read at all on this machine.
    func coverage(in root: FileSystemRoot) async -> RegistrationCoverage
    func snapshot(in root: FileSystemRoot) async -> RegistrationSnapshot
}

public struct RegistrationSnapshot: Sendable {
    public let registrations: [Registration]
    public let coverage: RegistrationCoverage
    public let observedAt: Date
    public let readerVersion: Int
    public init(registrations: [Registration], coverage: RegistrationCoverage,
                observedAt: Date = Date(), readerVersion: Int = 1) {
        self.registrations = registrations
        self.coverage = coverage
        self.observedAt = observedAt
        self.readerVersion = readerVersion
    }
}

public extension RegistrationSurface {
    func snapshot(in root: FileSystemRoot) async -> RegistrationSnapshot {
        let coverage = await coverage(in: root)
        return await RegistrationSnapshot(registrations: coverage.available ? registrations(in: root) : [],
                                          coverage: coverage)
    }
}

public actor RegistrationInventory {
    private let surfaces: [any RegistrationSurface]

    public init(surfaces: [any RegistrationSurface]) {
        self.surfaces = surfaces
    }

    public func snapshot(in root: FileSystemRoot) async -> RegistrationReport {
        let results = await withTaskGroup(of: (Int, RegistrationSnapshot).self) { group in
            for (index, source) in surfaces.enumerated() {
                group.addTask { await (index, source.snapshot(in: root)) }
            }
            var results: [Int: RegistrationSnapshot] = [:]
            for await (index, result) in group {
                results[index] = result
            }
            return results
        }
        let ordered = surfaces.indices.compactMap { results[$0] }
        return RegistrationReport(registrations: ordered.flatMap(\.registrations),
                                  coverage: ordered.map(\.coverage))
    }

    /// Every registration on the machine, from every readable surface, run
    /// together: none depends on another, and each is a `Sendable` value with no
    /// shared mutable state. Sorted afterwards, so the order does not depend on
    /// which finished first.
    public func all(in root: FileSystemRoot) async -> [Registration] {
        let surfaces = surfaces
        let results = await withTaskGroup(of: [Registration].self) { group in
            for surface in surfaces {
                group.addTask { await surface.registrations(in: root) }
            }
            var collected: [Registration] = []
            for await found in group {
                collected.append(contentsOf: found)
            }
            return collected
        }
        // Stable order: stale first, since those are what a sweep is for.
        return results.sorted {
            if $0.isActionableStale != $1.isActionableStale {
                return $0.isActionableStale
            }
            if $0.kind != $1.kind {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.identifier < $1.identifier
        }
    }

    /// The registrations belonging to one application, minus anything a
    /// surviving application also claims. The shared veto applies to records as
    /// well as files: a suite registers several apps against one helper, and
    /// deregistering it for one breaks the others. One way only, like Tier S.
    public func owned(
        by identity: Identity,
        bundleURL: URL?,
        in root: FileSystemRoot,
        alsoClaimedBy otherClaimants: [(identity: Identity, bundleURL: URL?)] = []
    ) async -> [Registration] {
        let everything = await all(in: root)
        let mine = everything.filter { $0.belongs(to: identity, bundleURL: bundleURL) }
        guard !otherClaimants.isEmpty else { return mine }

        return mine.filter { registration in
            !otherClaimants.contains { other in
                guard !Self.isSameInstallation(other.identity, bundleURL: other.bundleURL,
                                               as: identity, bundleURL: bundleURL) else { return false }
                return registration.belongs(to: other.identity, bundleURL: other.bundleURL)
            }
        }
    }

    /// Which surviving applications also claim a registration, so the exclusion
    /// can name them.
    public func alsoClaiming(
        _ registration: Registration,
        besides identity: Identity,
        among candidates: [(identity: Identity, bundleURL: URL?)]
    ) -> [Identity] {
        let subject = identity.bundlePath.map { URL(fileURLWithPath: $0) }
        return candidates.compactMap { other in
            guard !Self.isSameInstallation(other.identity, bundleURL: other.bundleURL,
                                           as: identity, bundleURL: subject)
            else { return nil }
            return registration.belongs(to: other.identity, bundleURL: other.bundleURL)
                ? other.identity : nil
        }
    }

    private static func isSameInstallation(
        _ other: Identity, bundleURL: URL?, as identity: Identity, bundleURL subjectURL: URL?
    ) -> Bool {
        let otherPath = bundleURL ?? other.bundlePath.map { URL(fileURLWithPath: $0) }
        let subjectPath = subjectURL ?? identity.bundlePath.map { URL(fileURLWithPath: $0) }
        guard let otherPath, let subjectPath else { return other == identity }
        return otherPath.resolvingSymlinksInPath().path == subjectPath.resolvingSymlinksInPath().path
    }

    /// Registrations pointing at something no longer installed, excluding
    /// entries macOS owns, which cannot be removed.
    public func stale(in root: FileSystemRoot) async -> [Registration] {
        await all(in: root).filter(\.isActionableStale)
    }

    /// Which surfaces could be read, in the order given. Indexed rather than
    /// appended, because a task group finishes in any order.
    public func coverage(in root: FileSystemRoot) async -> [RegistrationCoverage] {
        let surfaces = surfaces
        return await withTaskGroup(of: (Int, RegistrationCoverage).self) { group in
            for (index, surface) in surfaces.enumerated() {
                group.addTask { await (index, surface.coverage(in: root)) }
            }
            var byIndex: [Int: RegistrationCoverage] = [:]
            for await (index, found) in group {
                byIndex[index] = found
            }
            return surfaces.indices.compactMap { byIndex[$0] }
        }
    }
}
