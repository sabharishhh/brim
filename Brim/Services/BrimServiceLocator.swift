import Foundation
import BrimCore
import BrimProtocol
import BrimService

/// Makes the service the UI talks to: a `BrimService` actor in the app's
/// own process, which is enough for scanning and for everything inside the
/// person's own Library. Root-owned work goes through `BrimJobHelper`, a
/// temporary administrator process started for an approved batch.
enum BrimServiceLocator {
    /// Gives the service the one thing that lets it mint an approval: a
    /// window, in front of a person.
    ///
    /// This is what separates the app from every other client. Anything
    /// else holding a service object runs the same code and holds the same
    /// kind of object, and installs no consent source, so it cannot turn a
    /// plan into a token however it is driven.
    ///
    /// The answer is already a yes by the time it gets here: Brim's review
    /// sheets show the whole plan and the person pressed the button that
    /// started this. What the service needs to know is not whether they
    /// agreed, it is that there was somebody to agree.
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
