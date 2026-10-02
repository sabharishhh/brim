import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// The label comes from the declaration, never from its filename.
public struct LaunchdJobDefinition: Equatable, Sendable {
    public let label: String
    public let program: String?
    public let bundleProgram: String?
    private let searchesStandardPath: Bool

    public init?(dictionary: [String: Any]) {
        guard let label = dictionary["Label"] as? String, !label.isEmpty,
              !label.contains("/"), !label.contains("\0") else { return nil }
        self.label = label
        program = (dictionary["Program"] as? String)
            ?? (dictionary["ProgramArguments"] as? [String])?.first
        bundleProgram = dictionary["BundleProgram"] as? String
        searchesStandardPath = dictionary["Program"] == nil
    }

    public static func read(_ path: String) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let dictionary = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any], let job = Self(dictionary: dictionary) else {
            throw NSError(domain: "BrimLaunchd", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The job has no valid launchd label."
            ])
        }
        return job
    }

    public func resolvedProgram(plistPath: String) -> String? {
        if let program, program.hasPrefix("/") {
            return program
        }
        if let bundleProgram, !bundleProgram.hasPrefix("/"),
           let boundary = plistPath.range(of: ".app/Contents/", options: .backwards) {
            let host = String(plistPath[..<boundary.lowerBound]) + ".app"
            let resolved = URL(fileURLWithPath: host).appendingPathComponent(bundleProgram).standardizedFileURL.path
            return resolved.hasPrefix(host + "/") ? resolved : nil
        }
        // launchd searches the standard executable locations for argv[0].
        // No match here does not prove that a declaration's target vanished.
        guard searchesStandardPath, let program, !program.contains("/") else { return nil }
        return ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map { $0 + "/" + program }
            .first { PathObservation.observe($0, followingLinks: true).isPresent }
    }
}
