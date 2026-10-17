import Foundation
import Testing

struct RegistrationMaintenanceContractTests {
    @Test func theServiceImplementsTheRegistrationMaintenanceProtocolRequirement() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/BrimService/BrimService.swift"),
                                encoding: .utf8)
        // The concrete method and the protocol must share a signature, or the
        // existential calls the default no-op.
        let signature = try NSRegularExpression(
            pattern: #"public\s+func\s+reconcileRegistrations\(\)\s+async\s*(?:->\s*(?:Void|\(\))\s*)?\{"#
        )
        #expect(signature.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) == 1,
                "Registration maintenance must satisfy the protocol's Void requirement.")
    }
}
