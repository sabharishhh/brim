import Foundation
import BrimCore
import BrimProtocol
import BrimService

/// Makes the service the UI talks to: a `BrimService` actor in the app's own
/// process. Root-owned work goes through a temporary administrator process
/// started for an approved batch.
enum BrimServiceLocator {
    /// The one thing that lets the service mint an approval: a window in front
    /// of a person. No other client installs a consent source, so none can turn
    /// a plan into a token. The answer is always yes here because the person
    /// has already reviewed the plan and pressed the button.
    private static let consentSource = ConsentSource { _ in true }

    static func makeService() -> any BrimServiceProtocol {
        let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brim")
        let planDir = support.appendingPathComponent("Plans")
        let journalDir = support.appendingPathComponent("Journals")

        try? FileManager.default.createDirectory(at: planDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)

        return BrimService(
            root: root,
            brimAppURL: Bundle.main.bundleURL,
            planStoreDirectory: planDir,
            journalStoreDirectory: journalDir,
            consent: consentSource
        )
    }
}
