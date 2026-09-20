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

/// Whether a surface was readable, so the UI can distinguish "nothing found"
/// from "could not look" — Milestone 5's gate requires every feature to
/// report its own gaps.
public struct RegistrationCoverage: Equatable, Sendable, Codable {
    public let kind: Registration.Kind
    public let available: Bool
    /// Why the surface is unavailable, in the user's terms.
    public let limitation: String?

    public init(kind: Registration.Kind, available: Bool, limitation: String? = nil) {
        self.kind = kind
        self.available = available
        self.limitation = limitation
    }

    public static func available(_ kind: Registration.Kind) -> RegistrationCoverage {
        RegistrationCoverage(kind: kind, available: true)
    }

    public static func unavailable(_ kind: Registration.Kind, _ limitation: String) -> RegistrationCoverage {
        RegistrationCoverage(kind: kind, available: false, limitation: limitation)
    }
}

/// Aggregates the surfaces, the way `EvidenceEngine` aggregates evidence.
public actor RegistrationInventory {
    private let surfaces: [any RegistrationSurface]

    public init(surfaces: [any RegistrationSurface]) {
        self.surfaces = surfaces
    }

    /// Every registration on the machine, from every readable surface.
    public func all(in root: FileSystemRoot) async -> [Registration] {
        var results: [Registration] = []
        for surface in surfaces {
            results.append(contentsOf: await surface.registrations(in: root))
        }
        // Stable order: stale first, since those are what a sweep is for.
        return results.sorted {
            if $0.isActionableStale != $1.isActionableStale { return $0.isActionableStale }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.identifier < $1.identifier
        }
    }

    /// The registrations belonging to one application — the set an uninstall
    /// must clear in addition to the files.
    public func owned(
        by identity: Identity,
        bundleURL: URL?,
        in root: FileSystemRoot
    ) async -> [Registration] {
        await all(in: root).filter { $0.belongs(to: identity, bundleURL: bundleURL) }
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

    public func coverage(in root: FileSystemRoot) async -> [RegistrationCoverage] {
        var results: [RegistrationCoverage] = []
        for surface in surfaces {
            results.append(await surface.coverage(in: root))
        }
        return results
    }
}
