import BrimProcess
import Foundation

extension Helper {
    func qualifyReceiptPayload(_ packageID: String) async throws {
        let receipt = URL(fileURLWithPath: PrivilegedReceiptRemoval.receiptDirectory)
            .appendingPathComponent(packageID + ".plist")
        guard let data = try? Data(contentsOf: receipt),
              let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let prefix = metadata["InstallPrefixPath"] as? String
        else {
            throw PrivilegedReceiptRemoval.Refusal.payloadNotGone
        }
        let result = try await NativeCommandRunner.run(executable: "/usr/sbin/pkgutil",
                                                       arguments: ["--only-files", "--files", packageID],
                                                       environment: [
                                                           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                                           "LANG": "C",
                                                           "LC_ALL": "C"
                                                       ], timeout: 10)
        guard result.termination == .exited(0), !result.outputTruncated,
              let listing = String(data: result.stdout, encoding: .utf8)
        else {
            throw PrivilegedReceiptRemoval.Refusal.payloadNotGone
        }
        try PrivilegedReceiptRemoval.checkPayload(listing: listing, prefix: prefix) { path in
            let components = URL(fileURLWithPath: path).pathComponents
            if components.count > 2, components[1] == "Volumes" {
                var mount = stat()
                guard lstat("/Volumes/" + components[2], &mount) == 0 else {
                    throw PrivilegedReceiptRemoval.Refusal.payloadNotGone
                }
            }
            var info = stat()
            if lstat(path, &info) == 0 {
                return true
            }
            let failure = errno
            guard failure == ENOENT || failure == ENOTDIR else {
                throw PrivilegedReceiptRemoval.Refusal.payloadNotGone
            }
            return false
        }
    }

    /// A fixed tool with fixed arguments. The package identifier has
    /// already been checked to contain nothing but identifier characters,
    /// and it is passed as an argument rather than through a shell.
    func runPkgutil(forgetting packageID: String) async throws -> Int32 {
        let result = try await NativeCommandRunner.run(
            executable: "/usr/sbin/pkgutil", arguments: ["--forget", packageID],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"],
            timeout: 10
        )
        guard case let .exited(status) = result.termination else {
            throw NSError(domain: "BrimHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The installer record command did not finish."
            ])
        }
        return status
    }
}
