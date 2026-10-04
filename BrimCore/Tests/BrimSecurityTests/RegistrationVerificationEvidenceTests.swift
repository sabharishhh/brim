import BrimCore
import BrimProtocol
import Foundation
import Testing

// swiftformat:disable wrapMultilineStatementBraces
struct RegistrationVerificationEvidenceTests {
    @Test(arguments: ["mismatchedKind", "partialNamespace", "unknownReader"])
    func incompleteCoverageNeverCertifiesAbsence(_ scenario: String) {
        let coverage = RegistrationCoverage(kind: scenario == "mismatchedKind" ? .backgroundItem : .launchdJob,
                                            available: true, scopes: scenario == "partialNamespace"
                                                ? [.init(namespace: "system", available: false)] : nil)
        let observation = RegistrationVerification(capability: .launchdJob, observedAt: Date(),
                                                   readerVersion: scenario == "unknownReader" ? 0 : 2,
                                                   coverage: coverage, remaining: [])
        #expect(observation.confirmedClear == false)
        #expect(observation.couldNotCheck)
    }

    @Test func aPreflightObservationCannotCertifyTheLaterRemoval() {
        let boundary = Date(timeIntervalSince1970: 1000)
        let preflight = RegistrationVerification(capability: .launchdJob, observedAt: boundary.addingTimeInterval(-1),
                                                 coverage: .available(.launchdJob), remaining: [])
        let report = Self.report([preflight], since: boundary)
        #expect(report.registrationsChecked.isEmpty)
        let fresh = RegistrationVerification(capability: .launchdJob, observedAt: boundary,
                                             coverage: .available(.launchdJob), remaining: [])
        #expect(Self.report([fresh], since: boundary).registrationsChecked == [.launchdJob])
    }

    @Test func conflictingReadsDoNotCountOneCapabilityAsClear() {
        let date = Date()
        let clear = RegistrationVerification(capability: .launchdJob, observedAt: date,
                                             coverage: .available(.launchdJob), remaining: [])
        let unreadable = RegistrationVerification(capability: .launchdJob, observedAt: date,
                                                  coverage: .unavailable(.launchdJob, "Could not read."), remaining: [])
        #expect(Self.report([clear, unreadable], since: date).registrationsChecked.isEmpty)
        #expect(Self.report([clear, clear], since: date).registrationsChecked == [.launchdJob])
    }

    @Test func recoveryAndSharedRegistrationsAreKeptApartFromAbsence() {
        let record = Registration(kind: .launchServices, identifier: "org.example.fixture", label: "Fixture",
                                  programPath: "/fixture/recovery/Example.app", targetExists: true,
                                  evidence: "Recovery copy.")
        let recovery = RegistrationVerification(capability: .launchServices, observedAt: Date(),
                                                coverage: .available(.launchServices), remaining: [],
                                                recoveryCopies: [record])
        let shared = RegistrationVerification(capability: .launchServices, observedAt: Date(),
                                              coverage: .available(.launchServices), remaining: [], preserved: [record])
        #expect(recovery.confirmedClear == false)
        #expect(shared.confirmedClear == false)
        #expect(recovery.couldNotCheck == false)
        #expect(shared.couldNotCheck == false)
    }

    @Test func acceptedResetCommandsDoNotCertifyPrivacyAbsence() {
        let date = Date()
        let privacyCoverage = RegistrationCoverage.withheld(.privacyGrant, "Individual grants cannot be listed.")
        let privacy = RegistrationVerification(capability: .privacyGrant, observedAt: date,
                                               coverage: privacyCoverage, remaining: [])
        let receipt = "Permission reset command completed for org.example.fixture"
        let report = Self.report([privacy], since: date, completedActions: [receipt])
        #expect(report.registrationsChecked.isEmpty)
        #expect(report.completedActions == [receipt])
        #expect(privacy.isReportOnly)
    }

    @Test func aFailedResetDoesNotClaimPermissionRecordsArePresent() throws {
        let plan = Plan(planId: UUID(), createdAt: Date(), engineVersion: "test", osVersion: "test",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Fixture")),
                        steps: [], excludedItems: [], expectedTotalBytes: 0)
        let report = RemovalReport.build(plan: plan, remaining: [], recorded: [:], staleRegistrations: 0,
                                         privacyResetFailed: true, survivingExtensions: nil)
        #expect(report.keptByMacOS.isEmpty)
        #expect(report.failedActions == ["Permission reset command did not complete."])
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        payload.removeValue(forKey: "failedActions")
        let legacy = try JSONDecoder().decode(RemovalReport.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(legacy.failedActions == nil)
    }

    @Test func savedObservationTimesDecodeAlongsideLegacyResults() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let result = VerificationResult(planId: UUID(), expectedBytes: 0, recoveredBytes: 0,
                                        success: true, observedAt: date)
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(VerificationResult.self, from: encoded)
        #expect(decoded.observedAt == date)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        payload.removeValue(forKey: "observedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let legacy = try JSONDecoder().decode(VerificationResult.self, from: legacyData)
        #expect(legacy.observedAt == nil)
    }

    private static func report(
        _ observations: [RegistrationVerification], since date: Date, completedActions: [String] = []
    ) -> RemovalReport {
        let plan = Plan(planId: UUID(), createdAt: date.addingTimeInterval(-10),
                        engineVersion: "test", osVersion: "test",
                        intent: PlanIntent(type: .uninstall, subjectIdentity: Identity(name: "Fixture")),
                        steps: [], excludedItems: [], expectedTotalBytes: 0)
        return RemovalReport.build(plan: plan, remaining: [], recorded: [:], staleRegistrations: 0,
                                   privacyResetFailed: false, survivingExtensions: nil,
                                   registrationObservations: observations, completedActions: completedActions,
                                   verificationStartedAt: date)
    }
}
