import Foundation

/// Analyzes a Plan to determine what capabilities are required to execute it fully.
public struct PermissionAdvisor: Sendable {
    
    public struct Advice: Equatable, Sendable {
        public let needsHelper: Bool
        public let needsFullDiskAccess: Bool
        public let refusedByOSCount: Int
        
        public var hasBlockers: Bool {
            return needsHelper || needsFullDiskAccess || refusedByOSCount > 0
        }
    }
    
    public init() {}
    
    public func advise(on plan: Plan) -> Advice {
        var needsHelper = false
        var needsFullDiskAccess = false
        var refused = 0
        
        for step in plan.steps {
            switch step.capability {
            case .needsHelper:
                needsHelper = true
            case .needsFullDiskAccess:
                needsFullDiskAccess = true
            case .refusedByOS:
                refused += 1
            case .ok:
                continue
            }
        }
        
        return Advice(
            needsHelper: needsHelper,
            needsFullDiskAccess: needsFullDiskAccess,
            refusedByOSCount: refused
        )
    }
}
