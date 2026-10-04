import Foundation
import Testing

struct RegistrationMaintenanceContractTests {
    @Test func theServiceImplementsTheRegistrationMaintenanceProtocolRequirement() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/BrimService/BrimService.swift"),
                                encoding: .utf8)
        // The concrete method returned [URL] while the protocol returned Void.
        // Home's existential therefore ran the default no-op, even though the
        // concrete real-environment test successfully cleared registrations.
        let signature = try NSRegularExpression(
            pattern: #"public\s+func\s+reconcileRegistrations\(\)\s+async\s*(?:->\s*(?:Void|\(\))\s*)?\{"#
        )
        #expect(signature.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) == 1,
                "Registration maintenance must satisfy the protocol's Void requirement.")
    }
}
