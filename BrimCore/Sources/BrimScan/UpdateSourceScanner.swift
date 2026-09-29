import Foundation
import BrimCore

/// Which Homebrew casks are installed, and which of them an application
/// belongs to. Read from the Caskroom on disk, with no network request.
public struct UpdateSourceScanner: Sendable {

    private let homebrewPrefixes: [String]

    public init(
        homebrewPrefixes: [String] = ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"]
    ) {
        self.homebrewPrefixes = homebrewPrefixes
    }

    /// Every cask Homebrew has installed, by its directory name.
    ///
    /// Read from the Caskroom rather than by running `brew list`, which
    /// takes seconds and needs Homebrew's Ruby to start. The directory is
    /// the same answer and costs one listing.
    public func installedCasks(fileManager: FileManager = .default) -> Set<String> {
        var casks: Set<String> = []
        for prefix in homebrewPrefixes {
            let caskroom = "\(prefix)/Caskroom"
            guard let names = try? fileManager.contentsOfDirectory(atPath: caskroom) else {
                continue
            }
            casks.formUnion(names.filter { !$0.hasPrefix(".") })
        }
        return casks
    }

    public static func matchingCask(
        for application: InstalledApplication, among casks: Set<String>
    ) -> String? {
        let candidates = [
            application.name,
            application.url.deletingPathExtension().lastPathComponent,
            application.identity.bundleID?.split(separator: ".").last.map(String.init) ?? "",
        ]
        for candidate in candidates where !candidate.isEmpty {
            let normalised = normalise(candidate)
            guard !normalised.isEmpty else { continue }
            if let hit = casks.first(where: { normalise($0) == normalised }) {
                return hit
            }
        }
        return nil
    }

    /// Lowercased, with everything that is not a letter or a number
    /// removed, so "boringNotch" and "boring-notch" are the same word and
    /// "Visual Studio Code" and "visual-studio-code" are too.
    static func normalise(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
