import Foundation
import os

/// Brim's privileged daemon, and deliberately almost nothing.
///
/// It runs as root, so every line here is worth more scrutiny than the
/// rest of the application put together. It links one small module, it
/// answers two questions, and it holds no state.
///
/// The previous attempt at a helper ran the whole of `BrimService` as
/// root. That is the wrong shape: a root process should be small enough to
/// read in one sitting, because anything it can be talked into doing, it
/// does as root.
private let log = Logger(subsystem: "com.sabharishhh.brim.jobhelper", category: "removal")

/// Runs the daemon. Both the package executable and the copy inside the
/// application bundle are two lines that call this, so the code that runs
/// as root is one thing, in one place, covered by the package's tests.
public enum BrimJobHelperDaemon {
    public static func run() -> Never {
        let helper = Helper()
        let listener = NSXPCListener(machServiceName: BrimJobHelper.machServiceName)
        listener.delegate = helper
        listener.resume()
        log.info("BrimJobHelper \(BrimJobHelper.version) listening")
        RunLoop.main.run()
        fatalError("the run loop returned, which it does not")
    }
}

final class Helper: NSObject, BrimJobHelperProtocol, NSXPCListenerDelegate {

    // MARK: - Who may speak to it

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // macOS invalidates the connection when the peer does not satisfy
        // this, which is the enforcement. The previous attempt set a
        // requirement naming the wrong application and the wrong team,
        // then returned true regardless, so it accepted everyone.
        //
        // Compiled first, because `setCodeSigningRequirement` raises on a
        // string it cannot parse rather than returning a failure, and a
        // root daemon crashing on an incoming connection is a worse
        // outcome than one refusing it.
        let requirement = BrimJobHelper.clientRequirement()
        guard BrimJobHelper.isWellFormed(requirement) else {
            log.error("refusing every connection: the client requirement will not compile")
            return false
        }
        connection.setCodeSigningRequirement(requirement)

        connection.exportedInterface = NSXPCInterface(with: BrimJobHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        // Deliberately not logging the peer's pid. A pid is reused, so it
        // names the wrong process by the time anybody reads the log, and
        // the grep test that keeps pids out of authorisation decisions is
        // worth more than the detail.
        log.info("accepted a connection from a peer that satisfied the requirement")
        return true
    }

    // MARK: - What it will do

    func version(withReply reply: @escaping (String) -> Void) {
        reply(BrimJobHelper.version)
    }

    /// Removes the quarantine, and nothing else.
    ///
    /// The one place this daemon deletes rather than sets aside, because
    /// there is nowhere left to set anything aside to. The path is a
    /// constant in this binary, never a parameter, so the interface still
    /// cannot be talked into removing something else.
    func uninstallSelf(withReply reply: @escaping (String?) -> Void) {
        let quarantine = URL(fileURLWithPath: BrimJobHelper.quarantineDirectory)
        guard FileManager.default.fileExists(atPath: quarantine.path) else {
            log.info("nothing to clean up on the way out")
            return reply(nil)
        }
        do {
            try FileManager.default.removeItem(at: quarantine)
            // The parent is Brim's own folder. Taken away only if Brim is
            // the only thing that was in it.
            let parent = quarantine.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: parent)
            }
            log.info("removed the quarantine")
            reply(nil)
        } catch {
            log.error("could not remove the quarantine: \(error.localizedDescription)")
            reply("Brim's helper could not clear the folder it kept set-aside files in: "
                  + error.localizedDescription)
        }
    }

    func removeDefunctJob(domain: String, name: String, withReply reply: @escaping (String?) -> Void) {
        do {
            let target = try PrivilegedJobRemoval.target(domain: domain, name: name)
            try setAside(target)
            log.info("set aside \(target.path, privacy: .public)")
            reply(nil)
        } catch let refusal as PrivilegedJobRemoval.Refusal {
            log.error("refused \(domain)/\(name, privacy: .public): \(refusal.explanation, privacy: .public)")
            reply(refusal.explanation)
        } catch {
            log.error("failed \(domain)/\(name, privacy: .public): \(error.localizedDescription)")
            reply(error.localizedDescription)
        }
    }

    // MARK: - Doing it without being tricked

    /// Moves the job file into a root-owned quarantine, having checked
    /// that it is what it claims to be.
    ///
    /// Everything happens through a file descriptor for the directory,
    /// opened with `O_NOFOLLOW`, so a symlink swapped in between the check
    /// and the move cannot redirect it. That gap is the classic way a root
    /// helper is turned into a tool for deleting something else.
    private func setAside(_ target: URL) throws {
        let directory = target.deletingLastPathComponent().path
        let name = target.lastPathComponent

        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PrivilegedJobRemoval.Refusal.notThere }
        defer { close(parent) }

        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PrivilegedJobRemoval.Refusal.notThere
        }
        // A symlink, a directory or a device is not a job file, whatever
        // it is called.
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw PrivilegedJobRemoval.Refusal.notARegularFile
        }
        guard info.st_size <= 64 * 1024 else {
            throw PrivilegedJobRemoval.Refusal.tooBigForAJobFile(Int(info.st_size))
        }

        // Read through the same descriptor, so what is judged is what is
        // moved.
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else { throw PrivilegedJobRemoval.Refusal.unreadable }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        guard let contents = try? handle.readToEnd() ?? Data() else {
            throw PrivilegedJobRemoval.Refusal.unreadable
        }

        // The rule that makes this safe to expose: a job that still runs
        // something present on this Mac is not a leftover and is never
        // removed, whoever is asking.
        guard PrivilegedJobRemoval.isDefunct(
            plist: contents,
            programExists: { FileManager.default.fileExists(atPath: $0) }
        ) else {
            throw PrivilegedJobRemoval.Refusal.stillWorking
        }

        try moveIntoQuarantine(parent: parent, name: name, from: directory)
    }

    /// Renames the file into the quarantine rather than unlinking it, so a
    /// mistake can be undone. Both directories are on the same volume, so
    /// this is one atomic rename and never a partial copy.
    private func moveIntoQuarantine(parent: Int32, name: String, from directory: String) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = URL(fileURLWithPath: BrimJobHelper.quarantineDirectory)
            .appendingPathComponent(stamp)
            .appendingPathComponent((directory as NSString).lastPathComponent)

        do {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PrivilegedJobRemoval.Refusal.couldNotQuarantine(error.localizedDescription)
        }

        let holding = open(destination.path, O_RDONLY | O_DIRECTORY)
        guard holding >= 0 else {
            throw PrivilegedJobRemoval.Refusal.couldNotQuarantine("the holding folder would not open")
        }
        defer { close(holding) }

        guard renameat(parent, name, holding, name) == 0 else {
            throw PrivilegedJobRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
    }
}
