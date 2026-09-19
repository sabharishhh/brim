import Foundation

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
    
    public init(index: Int, kind: StepKind, target: String, targetFingerprint: TargetFingerprint?, tier: EvidenceTier, evidence: String, expectedBytes: Int64, capability: Capability, reversible: Bool, costOfError: CostOfError) {
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
    }
}

public struct Plan: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let planId: UUID
    public let createdAt: Date
    public let engineVersion: String
    public let osVersion: String
    // In a real implementation `intent` and `requester` would have their own structs.
    public let intentType: String
    public let intentSubject: String
    public let requesterKind: String
    public let requesterIdentity: String
    public let steps: [Step]
    // Excluded items could be defined here
    public let expectedTotalBytes: Int64
    
    public init(planId: UUID, createdAt: Date, engineVersion: String, osVersion: String, intentType: String, intentSubject: String, requesterKind: String, requesterIdentity: String, steps: [Step], expectedTotalBytes: Int64) {
        self.formatVersion = 1
        self.planId = planId
        self.createdAt = createdAt
        self.engineVersion = engineVersion
        self.osVersion = osVersion
        self.intentType = intentType
        self.intentSubject = intentSubject
        self.requesterKind = requesterKind
        self.requesterIdentity = requesterIdentity
        self.steps = steps
        self.expectedTotalBytes = expectedTotalBytes
    }
    
    /// Canonical JSON encoding required for deterministic hashing.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
