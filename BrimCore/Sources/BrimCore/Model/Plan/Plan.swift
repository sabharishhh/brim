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
}

public struct PlanIntent: Codable, Equatable, Sendable {
    public let type: IntentType
    public let subjectIdentity: Identity
    
    public init(type: IntentType, subjectIdentity: Identity) {
        self.type = type
        self.subjectIdentity = subjectIdentity
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
}
