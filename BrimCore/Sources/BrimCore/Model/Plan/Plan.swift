import Foundation
import CryptoKit

public enum Capability: String, Codable, Equatable, Sendable {
    case ok
    case needsHelper
    case needsFullDiskAccess
    case refusedByOS
}

public enum CostOfError: String, Codable, Equatable, Sendable {
    case low = "Recreatable cache or temp file"
    case medium = "App settings or generic data"
    case high = "User-created documents or system-level configuration"
}

public enum StepKind: String, Codable, Equatable, Sendable, CaseIterable {
    case trashPath
    case trashPathPrivileged
    case unloadLaunchdJob
    case removeLaunchdPlist
    case resetPrivacyGrants
    case forgetReceipt
    case clearImmutableFlag
    case delegateToolCleanup
    case revealVendorUninstaller
    case archivePath
    /// Removes the bundle's Launch Services registration, after the bundle
    /// itself is gone. Deleting an app does not retract its registration:
    /// the record survives, so the app keeps appearing in "Open With" and
    /// keeps claiming its document types and URL schemes.
    case unregisterLaunchServices
}

extension StepKind {
    /// Whether this step's `target` names a file, rather than an identifier
    /// such as a bundle id or a launchd label. Anything reading a target as
    /// a path — the "already gone" check, verification — has to ask first.
    public var targetIsPath: Bool {
        switch self {
        case .resetPrivacyGrants, .forgetReceipt, .delegateToolCleanup:
            // Each of these names an identifier: a bundle id, a package id,
            // or which cleanup to run. None is a file.
            return false
        case .trashPath, .trashPathPrivileged, .unloadLaunchdJob, .removeLaunchdPlist,
             .clearImmutableFlag, .revealVendorUninstaller,
             .archivePath, .unregisterLaunchServices:
            return true
        }
    }
}

public struct TargetFingerprint: Codable, Equatable, Sendable {
    public let dev: Int32
    public let ino: UInt64
    public let mtime: Date
    
    public init(dev: Int32, ino: UInt64, mtime: Date) {
        self.dev = dev
        self.ino = ino
        self.mtime = mtime
    }
    
    /// Equal when the file is the same file, allowing 10ms of drift in the
    /// modification time because a date that has been through JSON is not
    /// the date that went in.
    ///
    /// This used to print on every mismatch. An `==` is not the place: it
    /// runs for comparisons that are not safety decisions, it has no plan or
    /// step to name, and the one caller where a mismatch means something,
    /// `BrimService.apply` re-planning and comparing, already builds a
    /// message naming the step, the target and both fingerprints, and throws
    /// it as `ApplyError.validationFailed`.
    public static func == (lhs: TargetFingerprint, rhs: TargetFingerprint) -> Bool {
        let timeDiff = abs(lhs.mtime.timeIntervalSince1970 - rhs.mtime.timeIntervalSince1970)
        return lhs.dev == rhs.dev && lhs.ino == rhs.ino && timeDiff <= 0.01
    }
}

public enum ExecutionPhase: Int, Codable, Equatable, Sendable, Comparable {
    /// Clearing privacy grants, which must happen while the application
    /// bundle is still present: tccutil resolves the bundle through Launch
    /// Services, so after removal the grants can never be cleared again.
    case privacyReset = -2
    case archive = -1
    case auxiliary = 0
    case launchd = 1
    case appBundle = 2
    /// Retracting registrations that name the bundle. This runs *after* the
    /// bundle is removed — the mirror image of `privacyReset`. Unregistering
    /// a bundle that is still on disk achieves nothing, because Launch
    /// Services re-registers it the moment anything looks at it again.
    case registration = 3
    
    public static func < (lhs: ExecutionPhase, rhs: ExecutionPhase) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// What happens to a target when a step runs.
public enum StepDisposition: String, Codable, Equatable, Sendable {
    /// Moved to the Trash. Reversible by `undo` until the Trash is emptied,
    /// and it frees no disk space until then.
    case trash
    /// Removed outright. Frees the space immediately and cannot be undone.
    case delete

    /// Nobody restores a rebuilt cache, and leaving it in the Trash means the
    /// space the user was promised is not actually returned. Anything that
    /// carries settings or user data stays reversible.
    public static func `default`(for costOfError: CostOfError) -> StepDisposition {
        switch costOfError {
        case .low: return .delete
        case .medium, .high: return .trash
        }
    }
}

public struct Step: Codable, Equatable, Sendable {
    public let index: Int
    public let kind: StepKind
    public let target: String
    public let targetFingerprint: TargetFingerprint?
    public let tier: EvidenceTier
    public let evidence: String
    public let expectedBytes: Int64
    public let capability: Capability
    public let reversible: Bool
    public let costOfError: CostOfError
    public let executionPhase: ExecutionPhase
    public let archiveDestination: String?
    /// Absent in plans written before dispositions existed; those were all
    /// trashed, which `effectiveDisposition` preserves.
    public let disposition: StepDisposition?

    /// The disposition to act on, including for plans that predate the field.
    public var effectiveDisposition: StepDisposition { disposition ?? .trash }

    public init(index: Int, kind: StepKind, target: String, targetFingerprint: TargetFingerprint?, tier: EvidenceTier, evidence: String, expectedBytes: Int64, capability: Capability, reversible: Bool, costOfError: CostOfError, executionPhase: ExecutionPhase = .auxiliary, archiveDestination: String? = nil, disposition: StepDisposition? = nil) {
        self.index = index
        self.kind = kind
        self.target = target
        self.targetFingerprint = targetFingerprint
        self.tier = tier
        self.evidence = evidence
        self.expectedBytes = expectedBytes
        self.capability = capability
        self.reversible = reversible
        self.costOfError = costOfError
        self.executionPhase = executionPhase
        self.archiveDestination = archiveDestination
        self.disposition = disposition
    }
}

public struct ExcludedItem: Codable, Equatable, Sendable {
    public let target: String
    public let reason: String
    /// What Brim knows about the row, written the way a step's evidence is,
    /// so a row the sheet offers says how Brim found it.
    public let evidence: String?
    public let sizeBytes: Int64?
    public let tier: EvidenceTier?
    /// Whether the person may tick this row in the uninstall sheet. True for
    /// a row Brim found and left unticked; false for one that was vetoed,
    /// which stays out whatever is asked. Nil in plans written before the
    /// sheet could offer a row, and read as false.
    public let canBeTickedByHand: Bool?

    public init(
        target: String, reason: String,
        evidence: String? = nil, sizeBytes: Int64? = nil, canBeTickedByHand: Bool? = nil,
        tier: EvidenceTier? = nil
    ) {
        self.target = target
        self.reason = reason
        self.evidence = evidence
        self.sizeBytes = sizeBytes
        self.tier = tier
        self.canBeTickedByHand = canBeTickedByHand
    }
}

public enum IntentType: String, Codable, Equatable, Sendable {
    case uninstall
    case reset
    case archive
}

public struct PlanIntent: Codable, Equatable, Sendable {
    public let type: IntentType
    public let subjectIdentity: Identity
    public let requesterKind: String
    public let requesterIdentity: String
    public let specificTarget: URL?
    /// Several explicitly chosen targets planned as one unit, so a multi-item
    /// selection produces a single plan the user approves once. Absent in
    /// plans written before batching existed, hence optional.
    public let specificTargets: [URL]?
    public let destinationTarget: URL?
    public let archiveAndUninstall: Bool
    /// Rows Brim found for this application and did not tick, which the
    /// person ticked in the uninstall sheet. Paths, exactly as the plan's
    /// excluded rows name them.
    ///
    /// On the intent rather than beside it, so it is part of what the person
    /// approves, since the plan's hash covers the intent, and part of what
    /// `apply` rebuilds when it checks the plan again before touching
    /// anything. Absent in plans written before the sheet could offer an
    /// unticked row, hence optional, and absent from the encoding when nil so
    /// every other plan hashes as it always has.
    ///
    /// It can only promote. A path here that the evidence engine did not
    /// find for this application is ignored, and a row that was vetoed stays
    /// vetoed; `Planner` holds both, and `TickedByHandPlannerTests` holds the
    /// planner to them.
    public private(set) var tickedByHand: [String]?

    /// The explicit targets this intent asks for, however they were supplied.
    /// Empty means "discover the footprint from the identity".
    public var explicitTargets: [URL] {
        if let many = specificTargets, !many.isEmpty { return many }
        if let one = specificTarget { return [one] }
        return []
    }

    public init(type: IntentType, subjectIdentity: Identity, requesterKind: String = "ui", requesterIdentity: String = "user", specificTarget: URL? = nil, specificTargets: [URL]? = nil, destinationTarget: URL? = nil, archiveAndUninstall: Bool = false, tickedByHand: [String]? = nil) {
        self.type = type
        self.subjectIdentity = subjectIdentity
        self.requesterKind = requesterKind
        self.requesterIdentity = requesterIdentity
        self.specificTarget = specificTarget
        self.specificTargets = specificTargets
        self.destinationTarget = destinationTarget
        self.archiveAndUninstall = archiveAndUninstall
        self.tickedByHand = tickedByHand
    }

    /// The same intent with a different set of rows ticked by hand. Sorted,
    /// so one choice always makes one intent and one plan hash, and nil when
    /// nothing is ticked, so it encodes as though the sheet never offered.
    ///
    /// A copy with one field changed rather than a new intent built from the
    /// old one's fields, so a field added to the intent later cannot be
    /// quietly dropped from every plan the sheet rebuilds.
    public func tickingByHand(_ paths: Set<String>) -> PlanIntent {
        var copy = self
        copy.tickedByHand = paths.isEmpty ? nil : paths.sorted()
        return copy
    }
}

public struct Plan: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let planId: UUID
    public let createdAt: Date
    public let engineVersion: String
    public let osVersion: String
    
    public let intent: PlanIntent
    public let steps: [Step]
    public let excludedItems: [ExcludedItem]
    
    public let expectedTotalBytes: Int64
    
    public init(planId: UUID, createdAt: Date, engineVersion: String, osVersion: String, intent: PlanIntent, steps: [Step], excludedItems: [ExcludedItem], expectedTotalBytes: Int64) {
        self.formatVersion = 1
        self.planId = planId
        self.createdAt = createdAt
        self.engineVersion = engineVersion
        self.osVersion = osVersion
        self.intent = intent
        self.steps = steps
        self.excludedItems = excludedItems
        self.expectedTotalBytes = expectedTotalBytes
    }
    
    /// Canonical JSON encoding required for deterministic hashing.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        
        return try encoder.encode(self)
    }
    
    public func contentHash() throws -> String {
        let data = try canonicalData()
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Bytes this plan frees the moment it runs, because those targets are
    /// deleted outright rather than moved to the Trash.
    public var immediatelyFreedBytes: Int64 {
        steps.filter { $0.effectiveDisposition == .delete }.reduce(0) { $0 + $1.expectedBytes }
    }

    /// Bytes that only come back once the user empties the Trash. Reporting
    /// these as reclaimed is what made the headline figure misleading.
    public var trashedBytes: Int64 {
        steps.filter { $0.effectiveDisposition == .trash }.reduce(0) { $0 + $1.expectedBytes }
    }

    /// Whether `undo` can put anything back. False once every step in the plan
    /// was a permanent delete.
    public var isReversible: Bool {
        steps.contains { $0.effectiveDisposition == .trash }
    }

    /// Steps in the order they must be applied: archive first so a copy exists
    /// before anything is destroyed, then auxiliary files, then launchd jobs
    /// (unloaded before their plist goes), and the app bundle last. Ties
    /// within a phase keep the planner's own order.
    public var executionOrderedSteps: [Step] {
        steps.sorted { a, b in
            if a.executionPhase != b.executionPhase {
                return a.executionPhase < b.executionPhase
            }
            return a.index < b.index
        }
    }

    /// Steps in the order they must be undone: the exact reverse of
    /// `executionOrderedSteps`, so the app bundle is put back before the
    /// auxiliary files that live beneath it and a launchd job is only
    /// reloaded once its plist has been restored.
    public var undoOrderedSteps: [Step] {
        steps.sorted { a, b in
            if a.executionPhase != b.executionPhase {
                return a.executionPhase > b.executionPhase
            }
            return a.index > b.index
        }
    }
}
