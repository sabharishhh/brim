import CryptoKit
import Foundation

// swiftformat:disable wrapMultilineStatementBraces

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
    /// Removes the bundle's Launch Services registration after the bundle has
    /// gone. Deleting an app does not retract it, so the app would stay in
    /// "Open With" and keep claiming its document types and URL schemes.
    case unregisterLaunchServices
    /// Removes only the Dock shortcut for the reviewed application path.
    case removeDockShortcut
}

public extension StepKind {
    /// Whether this step's `target` names a file, rather than an identifier
    /// such as a bundle id or a launchd label. Anything reading a target as
    /// a path (the "already gone" check, verification) has to ask first.
    var targetIsPath: Bool {
        switch self {
        case .resetPrivacyGrants, .forgetReceipt, .delegateToolCleanup, .removeDockShortcut:
            // Each of these names an identifier: a bundle id, a package id,
            // or which cleanup to run. None is a file.
            false
        case .trashPath, .trashPathPrivileged, .unloadLaunchdJob, .removeLaunchdPlist,
             .clearImmutableFlag, .revealVendorUninstaller,
             .unregisterLaunchServices:
            true
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

    /// The same file, allowing 10 ms of drift in the modification time, because
    /// a date that has been through JSON is not exactly the date that went in.
    public static func == (lhs: TargetFingerprint, rhs: TargetFingerprint) -> Bool {
        let timeDiff = abs(lhs.mtime.timeIntervalSince1970 - rhs.mtime.timeIntervalSince1970)
        return lhs.dev == rhs.dev && lhs.ino == rhs.ino && timeDiff <= 0.01
    }
}

public enum ExecutionPhase: Int, Codable, Equatable, Sendable, Comparable {
    /// Clearing privacy grants while the bundle still exists: `tccutil` finds
    /// the bundle through Launch Services, so afterwards the grants can never be
    /// cleared.
    case privacyReset = -2
    case auxiliary = 0
    case launchd = 1
    case appBundle = 2
    /// Retracting registrations after the bundle is removed, the mirror of
    /// `privacyReset`: Launch Services re-registers a bundle still on disk.
    case registration = 3

    public static func < (lhs: ExecutionPhase, rhs: ExecutionPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What happens to a target when a step runs.
public enum StepDisposition: String, Codable, Equatable, Sendable {
    /// Moved to the Trash. Reversible by `undo` until the Trash is emptied,
    /// and it frees no disk space until then.
    case trash
    /// Removed outright. Frees the space immediately and cannot be undone.
    case delete

    /// A rebuilt cache is deleted outright so its space really comes back.
    /// Anything with settings or user data stays reversible.
    public static func `default`(for costOfError: CostOfError) -> StepDisposition {
        switch costOfError {
        case .low: .delete
        case .medium, .high: .trash
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
    /// Nil in older plans, whose sizes were measured by the scanner.
    public let sizeIsKnown: Bool?
    /// The identifier read before an application copy is removed. Older plans omit it.
    public let registrationBundleID: String?
    public let capability: Capability
    public let reversible: Bool
    public let costOfError: CostOfError
    public let executionPhase: ExecutionPhase
    /// Absent in plans written before dispositions existed; those were all
    /// trashed, which `effectiveDisposition` preserves.
    public let disposition: StepDisposition?

    /// The disposition to act on, including for plans that predate the field.
    public var effectiveDisposition: StepDisposition {
        disposition ?? .trash
    }

    public init(index: Int, kind: StepKind, target: String, targetFingerprint: TargetFingerprint?, tier: EvidenceTier, evidence: String, expectedBytes: Int64, capability: Capability, reversible: Bool, costOfError: CostOfError, executionPhase: ExecutionPhase = .auxiliary, disposition: StepDisposition? = nil, sizeIsKnown: Bool? = nil, registrationBundleID: String? = nil) {
        self.index = index
        self.kind = kind
        self.target = target
        self.targetFingerprint = targetFingerprint
        self.tier = tier
        self.evidence = evidence
        self.expectedBytes = expectedBytes
        self.sizeIsKnown = sizeIsKnown
        self.registrationBundleID = registrationBundleID
        self.capability = capability
        self.reversible = reversible
        self.costOfError = costOfError
        self.executionPhase = executionPhase
        self.disposition = disposition
    }
}

public struct ExcludedItem: Codable, Equatable, Sendable {
    public let target: String
    public let reason: String
    /// What Brim knows about the row, written like a step's evidence.
    public let evidence: String?
    public let sizeBytes: Int64?
    public let tier: EvidenceTier?
    /// Whether the person may tick this row in the review: true for a row Brim
    /// found and left unticked, false for a vetoed one. Nil in older plans,
    /// read as false.
    public let canBeTickedByHand: Bool?

    public init(target: String, reason: String, evidence: String? = nil, sizeBytes: Int64? = nil, canBeTickedByHand: Bool? = nil, tier: EvidenceTier? = nil) {
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
    case toolCleanup
}

public struct PlanIntent: Codable, Equatable, Sendable {
    public let type: IntentType
    public let subjectIdentity: Identity
    public let requesterKind: String
    public let requesterIdentity: String
    public let toolCleanup: ToolCleanupRequest?
    public let specificTarget: URL?
    /// Several chosen targets planned as one unit, approved once. Optional for
    /// older plans.
    public let specificTargets: [URL]?
    public let excludedFolders: [URL]?
    /// Rows Brim found and did not tick that the person ticked in the review.
    /// On the intent, so the plan's hash covers them and `apply` rebuilds them.
    /// It can only promote: a path the evidence engine did not find is ignored
    /// and a vetoed row stays vetoed (`TickedByHandPlannerTests`). Absent from
    /// the encoding when nil, so other plans hash as before.
    public private(set) var tickedByHand: [String]?

    /// The explicit targets this intent asks for, however they were supplied.
    /// Empty means "discover the footprint from the identity".
    public var explicitTargets: [URL] {
        if let many = specificTargets, !many.isEmpty {
            return many
        }
        if let one = specificTarget {
            return [one]
        }
        return []
    }

    public init(type: IntentType, subjectIdentity: Identity, requesterKind: String = "ui", requesterIdentity: String = "user", specificTarget: URL? = nil, specificTargets: [URL]? = nil, tickedByHand: [String]? = nil, toolCleanup: ToolCleanupRequest? = nil, excludedFolders: [URL]? = nil) {
        self.type = type
        self.toolCleanup = toolCleanup
        self.subjectIdentity = subjectIdentity
        self.requesterKind = requesterKind
        self.requesterIdentity = requesterIdentity
        self.specificTarget = specificTarget
        self.specificTargets = specificTargets
        self.excludedFolders = excludedFolders?.isEmpty == false ? excludedFolders : nil
        self.tickedByHand = tickedByHand
    }

    /// The same intent with different rows ticked by hand. Sorted, so one choice
    /// gives one plan hash; nil when nothing is ticked. A copy with one field
    /// changed, so a field added later is never dropped.
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
    /// Absent in older plans and complete scans. Included in the approval hash.
    public let scanCompleteness: ScanCompleteness?
    public let toolCleanupBinding: ToolCleanupBinding?
    /// Included in the approval hash. Nil for plans made before this report existed.
    public private(set) var capabilityReport: CapabilitySearchReport?
    public private(set) var homebrewInstallation: HomebrewInstallation?
    /// Reviewed installations that protect identifier-wide state. Nil in older plans.
    public let survivingCopies: [Identity]?
    public let protectedComponentIdentifiers: [String]?
    /// Complete receipt payloads reviewed before forgetting any installer record.
    public let receiptPayloads: [String: [String]]?
    /// Dock failure is a review note, not a reason to abandon the app removal.
    public private(set) var dockShortcutReadError: String?

    public let expectedTotalBytes: Int64

    public init(planId: UUID, createdAt: Date, engineVersion: String, osVersion: String,
                intent: PlanIntent, steps: [Step], excludedItems: [ExcludedItem], expectedTotalBytes: Int64,
                scanCompleteness: ScanCompleteness? = nil, capabilityReport: CapabilitySearchReport? = nil,
                toolCleanupBinding: ToolCleanupBinding? = nil, homebrewInstallation: HomebrewInstallation? = nil,
                survivingCopies: [Identity]? = nil, protectedComponentIdentifiers: [String]? = nil,
                receiptPayloads: [String: [String]]? = nil) {
        self.receiptPayloads = receiptPayloads?.isEmpty == false ? receiptPayloads : nil
        self.protectedComponentIdentifiers = protectedComponentIdentifiers
        formatVersion = 1
        self.planId = planId
        self.createdAt = createdAt
        self.engineVersion = engineVersion
        self.osVersion = osVersion
        self.intent = intent
        self.steps = steps
        self.excludedItems = excludedItems
        self.scanCompleteness = scanCompleteness?.isComplete == false ? scanCompleteness : nil
        self.capabilityReport = capabilityReport
        self.toolCleanupBinding = toolCleanupBinding
        self.homebrewInstallation = homebrewInstallation
        self.survivingCopies = survivingCopies?.isEmpty == false ? Array(Set(survivingCopies ?? [])).sorted {
            ($0.bundlePath ?? "", $0.name) < ($1.bundlePath ?? "", $1.name)
        } : nil
        self.expectedTotalBytes = expectedTotalBytes
    }

    public func attaching(_ report: CapabilitySearchReport?) -> Plan {
        var copy = self
        copy.capabilityReport = report
        return copy
    }

    public func recording(_ installation: HomebrewInstallation?) -> Plan {
        var copy = self
        copy.homebrewInstallation = installation
        return copy
    }

    public func recordingDockShortcutError(_ error: String?) -> Plan {
        var copy = self
        copy.dockShortcutReadError = error
        return copy
    }

    /// Canonical JSON encoding required for deterministic hashing.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dates.string(from: date))
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
        ordinaryFileRemovals.filter { $0.effectiveDisposition == .delete }.reduce(0) { $0 + $1.expectedBytes }
    }

    /// Bytes that come back only once the Trash is emptied.
    public var trashedBytes: Int64 {
        ordinaryFileRemovals.filter { $0.effectiveDisposition == .trash }.reduce(0) { $0 + $1.expectedBytes }
    }

    /// The helper moves these files aside without a supported restore action.
    public var setAsideBytes: Int64 {
        steps.filter { $0.kind == .trashPathPrivileged && $0.effectiveDisposition == .trash }
            .reduce(0) { $0 + $1.expectedBytes }
    }

    private var ordinaryFileRemovals: [Step] {
        steps.filter { $0.kind == .trashPath || $0.kind == .removeLaunchdPlist
            || ($0.kind == .trashPathPrivileged && $0.effectiveDisposition == .delete)
        }
    }

    /// Whether `undo` can put anything back. False once every step in the plan
    /// was a permanent delete.
    public var isReversible: Bool {
        steps.contains {
            $0.effectiveDisposition == .trash && ($0.kind == .trashPath || $0.kind == .removeLaunchdPlist)
        }
    }

    /// Steps in the order they must run: privacy grants while the bundle
    /// exists, then auxiliary files, then launchd jobs (unloaded before their
    /// plist goes), and the app bundle last. Ties keep the planner's order.
    public var executionOrderedSteps: [Step] {
        steps.sorted { a, b in
            if a.executionPhase != b.executionPhase {
                return a.executionPhase < b.executionPhase
            }
            return a.index < b.index
        }
    }

    /// The exact reverse of `executionOrderedSteps`, so the bundle comes back
    /// before the files beneath it and a job reloads only after its plist.
    public var undoOrderedSteps: [Step] {
        steps.sorted { a, b in
            if a.executionPhase != b.executionPhase {
                return a.executionPhase > b.executionPhase
            }
            return a.index > b.index
        }
    }
}
