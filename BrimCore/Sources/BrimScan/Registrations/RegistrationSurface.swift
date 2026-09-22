import Foundation
import BrimCore

/// A place macOS records that an application exists, other than the
/// filesystem.
///
/// Mirrors `EvidenceSource`, deliberately: one surface per mechanism, each
/// enumerating what it knows about and saying in a sentence how it knows.
/// One enumeration then serves both questions — *what belongs to this app*,
/// for an uninstall, and *what belongs to nothing*, for the stale sweep.
public protocol RegistrationSurface: Sendable {
    var kind: Registration.Kind { get }

    /// Everything this mechanism currently holds.
    ///
    /// Returns an empty list rather than throwing when the mechanism is
    /// unavailable; `coverage` reports why, so a surface that could not be
    /// read is never mistaken for one that found nothing.
    func registrations(in root: FileSystemRoot) async -> [Registration]

    /// Whether this surface could be read at all on this machine.
    func coverage(in root: FileSystemRoot) async -> RegistrationCoverage
}

public actor RegistrationInventory {
    private let surfaces: [any RegistrationSurface]

    public init(surfaces: [any RegistrationSurface]) {
        self.surfaces = surfaces
    }

    /// Every registration on the machine, from every readable surface.
    ///
    /// The surfaces run together. Each one waits on something different and
    /// none of them needs any of the others: `pluginkit` is a subprocess,
    /// Background Task Management is a file read, the launchd folders and
    /// the plug-in folders are directory walks, and the privileged helper
    /// surface verifies code signatures. Run one after another they added
    /// up to the slowest thing the app does at launch; run together the
    /// scan costs about what its slowest member costs.
    ///
    /// `RegistrationSurface` is `Sendable` and every surface is a value
    /// with no shared mutable state, which is what makes this safe rather
    /// than hopeful. The result is sorted afterwards, so the order does not
    /// depend on which task finished first.
    public func all(in root: FileSystemRoot) async -> [Registration] {
        let surfaces = self.surfaces
        let results = await withTaskGroup(of: [Registration].self) { group in
            for surface in surfaces {
                group.addTask { await surface.registrations(in: root) }
            }
            var collected: [Registration] = []
            for await found in group { collected.append(contentsOf: found) }
            return collected
        }
        // Stable order: stale first, since those are what a sweep is for.
        return results.sorted {
            if $0.isActionableStale != $1.isActionableStale { return $0.isActionableStale }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.identifier < $1.identifier
        }
    }

    /// The registrations belonging to one application, minus anything a
    /// surviving application also claims.
    ///
    /// The shared-file veto applies to registrations, not only to files.
    /// Mole learned this the hard way and the specification says it in
    /// B4 and in `strategy.md`: a suite installs one login-item helper
    /// and several applications register against it, so uninstalling one
    /// of them and deregistering the helper breaks the two that remain.
    /// The file veto never saw these, because a registration is a record
    /// in a database and has no file to veto.
    ///
    /// One way only, exactly as Tier S is. This can take a registration
    /// out of the set and can never put one in.
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
                guard other.identity.bundleID != identity.bundleID else { return false }
                return registration.belongs(to: other.identity, bundleURL: other.bundleURL)
            }
        }
    }

    /// Which surviving applications claim a registration as well, so the
    /// exclusion can name them rather than saying "shared" and stopping.
    public func alsoClaiming(
        _ registration: Registration,
        besides identity: Identity,
        among candidates: [(identity: Identity, bundleURL: URL?)]
    ) -> [Identity] {
        candidates.compactMap { other in
            guard other.identity.bundleID != identity.bundleID else { return nil }
            return registration.belongs(to: other.identity, bundleURL: other.bundleURL)
                ? other.identity : nil
        }
    }

    /// Registrations pointing at something no longer installed, whichever
    /// application left them, excluding entries macOS owns.
    ///
    /// On a real machine Apple ships several launchd jobs whose programs are
    /// absent; they are not leftovers and cannot be removed, so surfacing
    /// them as cleanable would be both wrong and impossible to act on.
    public func stale(in root: FileSystemRoot) async -> [Registration] {
        await all(in: root).filter(\.isActionableStale)
    }

    /// Which surfaces could be read, in the order the surfaces were given.
    ///
    /// Together, like `all`, and indexed rather than appended because a
    /// task group finishes in whatever order it finishes in and this list
    /// is shown to a person.
    public func coverage(in root: FileSystemRoot) async -> [RegistrationCoverage] {
        let surfaces = self.surfaces
        return await withTaskGroup(of: (Int, RegistrationCoverage).self) { group in
            for (index, surface) in surfaces.enumerated() {
                group.addTask { (index, await surface.coverage(in: root)) }
            }
            var byIndex: [Int: RegistrationCoverage] = [:]
            for await (index, found) in group { byIndex[index] = found }
            return surfaces.indices.compactMap { byIndex[$0] }
        }
    }
}
