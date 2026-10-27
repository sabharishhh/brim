import Foundation

/// Protection-only metadata held for preview preparation. Execution asks the
/// reader again; a preview cache never establishes permission to remove data.
public struct BundleProtection: Sendable {
    public let surface: IdentitySurface
    public let complete: Bool
    public let cancelled: Bool

    public init(surface: IdentitySurface, complete: Bool, cancelled: Bool = false) {
        self.surface = surface
        self.complete = complete
        self.cancelled = cancelled
    }
}
