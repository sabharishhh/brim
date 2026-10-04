import Darwin
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
        if let value = dictionary["Program"], !(value is String) {
            return nil
        }
        if let value = dictionary["ProgramArguments"], !(value is [String]) {
            return nil
        }
        if let value = dictionary["BundleProgram"], !(value is String) {
            return nil
        }
        self.label = label
        program = (dictionary["Program"] as? String)
            ?? (dictionary["ProgramArguments"] as? [String])?.first
        bundleProgram = dictionary["BundleProgram"] as? String
        searchesStandardPath = dictionary["Program"] == nil
    }

    public static func read(_ path: String) throws -> Self {
        let data = try readBoundedDeclaration(path)
        guard let dictionary = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any], let job = Self(dictionary: dictionary) else {
            throw NSError(domain: "BrimLaunchd", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The job has no valid launchd label."
            ])
        }
        return job
    }

    private static func readBoundedDeclaration(_ path: String) throws -> Data {
        guard !path.contains("\0") else { throw unreadableDeclaration() }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let limit = 64 * 1024
        var reviewed = stat()
        guard fstat(descriptor, &reviewed) == 0, (reviewed.st_mode & S_IFMT) == S_IFREG,
              reviewed.st_size >= 0, reviewed.st_size <= Int64(limit),
              let data = try handle.read(upToCount: limit + 1), data.count == Int(reviewed.st_size)
        else { throw unreadableDeclaration() }
        var current = stat()
        guard fstat(descriptor, &current) == 0, sameEntry(current, reviewed),
              lstat(path, &current) == 0, sameEntry(current, reviewed)
        else { throw unreadableDeclaration() }
        return data
    }

    private static func sameEntry(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    private static func unreadableDeclaration() -> NSError {
        NSError(domain: "BrimLaunchd", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The job declaration is not a stable regular file "
                + "within the supported read limit."
        ])
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
