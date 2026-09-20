import XCTest
import Foundation
@testable import BrimCore
@testable import BrimProtocol
@testable import BrimService

final class TokenStoreTests: XCTestCase {
    
    func testTokenValidationScenarios() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = TokenStore(directoryURL: tempDir)
        
        let planId = UUID()
        let planHash = "somehash"
        let requester = "user"
        
        let token = await store.mintToken(planId: planId, planHash: planHash, requesterIdentity: requester)
        
        // 1. Replayed token fails
        do {
            try await store.consumeAndValidate(token: token, expectedPlanId: planId, expectedPlanHash: planHash, expectedRequesterIdentity: requester)
        } catch {
            XCTFail("First consumption should succeed")
        }
        
        do {
            try await store.consumeAndValidate(token: token, expectedPlanId: planId, expectedPlanHash: planHash, expectedRequesterIdentity: requester)
            XCTFail("Should have thrown notFound for replayed token")
        } catch TokenStore.TokenError.notFound {
            // Expected
        } catch {
            XCTFail("Unexpected error")
        }
        
        // 2. Different plan hash fails
        let token2 = await store.mintToken(planId: planId, planHash: planHash, requesterIdentity: requester)
        do {
            try await store.consumeAndValidate(token: token2, expectedPlanId: planId, expectedPlanHash: "otherhash", expectedRequesterIdentity: requester)
            XCTFail("Should have thrown planMismatch")
        } catch TokenStore.TokenError.planMismatch {
            // Expected
        }
        
        // 3. Different requester fails
        let token3 = await store.mintToken(planId: planId, planHash: planHash, requesterIdentity: requester)
        do {
            try await store.consumeAndValidate(token: token3, expectedPlanId: planId, expectedPlanHash: planHash, expectedRequesterIdentity: "other")
            XCTFail("Should have thrown requesterMismatch")
        } catch TokenStore.TokenError.requesterMismatch {
            // Expected
        }
    }
}
