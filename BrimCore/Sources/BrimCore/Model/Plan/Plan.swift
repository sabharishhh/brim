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

public enum StepKind: String, Codable, Equatable, Sendable {
    case trashPath
    case trashPathPrivileged
    case unloadLaunchdJob
    case removeLaunchdPlist
    case resetPrivacyGrants
    case forgetReceipt
    case clearImmutableFlag
    case delegateToolCleanup
    case revealVendorUninstaller
    case btmReset
    case archivePath
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
    
    public static func == (lhs: TargetFingerprint, rhs: TargetFingerprint) -> Bool {
        let timeDiff = abs(lhs.mtime.timeIntervalSince1970 - rhs.mtime.timeIntervalSince1970)
        if lhs.dev != rhs.dev || lhs.ino != rhs.ino || timeDiff > 0.01 {
            print("TARGET FINGERPRINT MISMATCH: dev=\(lhs.dev == rhs.dev) ino=\(lhs.ino == rhs.ino) diff=\(timeDiff)")
            return false
        }
        return true
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
    
    public init(target: String, reason: String) {
        self.target = target
        self.reason = reason
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

    /// The explicit targets this intent asks for, however they were supplied.
    /// Empty means "discover the footprint from the identity".
    public var explicitTargets: [URL] {
        if let many = specificTargets, !many.isEmpty { return many }
        if let one = specificTarget { return [one] }
        return []
    }

    public init(type: IntentType, subjectIdentity: Identity, requesterKind: String = "ui", requesterIdentity: String = "user", specificTarget: URL? = nil, specificTargets: [URL]? = nil, destinationTarget: URL? = nil, archiveAndUninstall: Bool = false) {
        self.type = type
        self.subjectIdentity = subjectIdentity
        self.requesterKind = requesterKind
        self.requesterIdentity = requesterIdentity
        self.specificTarget = specificTarget
        self.specificTargets = specificTargets
        self.destinationTarget = destinationTarget
        self.archiveAndUninstall = archiveAndUninstall
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
