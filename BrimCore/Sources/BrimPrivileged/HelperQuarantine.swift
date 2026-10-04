import BrimProcess
import Foundation

extension Helper {
    // MARK: - Doing it without being tricked

    /// Moves a dead command link into the quarantine, having proved it is
    /// dead through the directory's own descriptor.
    ///
    /// A rename where the volume allows one. Where it does not, the link is
    /// written again inside the quarantine with the same destination and
    /// then removed: a link is nothing but its destination, so that copy
    /// is exact and it still puts back.
    func setAsideDeadLink(_ target: URL) throws {
        let directory = target.deletingLastPathComponent().path
        let name = target.lastPathComponent

        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PrivilegedLinkRemoval.Refusal.notThere }
        defer { close(parent) }

        let destination = try PrivilegedLinkRemoval.deadDestination(parent: parent, name: name)
        let holding = try openHoldingFolder(for: directory) { why in
            PrivilegedLinkRemoval.Refusal.couldNotQuarantine(why)
        }
        defer { close(holding) }

        if renameat(parent, name, holding, name) == 0 {
            return
        }
        guard errno == EXDEV else {
            throw PrivilegedLinkRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
        guard symlinkat(destination, holding, name) == 0 else {
            throw PrivilegedLinkRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
        guard unlinkat(parent, name, 0) == 0 else {
            throw PrivilegedLinkRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
    }

    /// A fresh, dated folder in the quarantine, named after the folder the
    /// item came from, opened as a descriptor.
    private func openHoldingFolder(
        for directory: String, refusal: (String) -> Error
    ) throws -> Int32 {
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
            throw refusal(error.localizedDescription)
        }
        let holding = open(destination.path, O_RDONLY | O_DIRECTORY)
        guard holding >= 0 else { throw refusal("the holding folder would not open") }
        return holding
    }

    /// Moves the job file into a root-owned quarantine, having checked
    /// that it is what it claims to be.
    ///
    /// Everything happens through a file descriptor for the directory,
    /// opened with `O_NOFOLLOW`, so a symlink swapped in between the check
    /// and the move cannot redirect it. That gap is the classic way a root
    /// helper is turned into a tool for deleting something else.
    func setAside(_ target: URL, requesterUID: uid_t?) async throws {
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
        let contents = try PrivilegedJobRemoval.readReviewedPlist(parent: parent, name: name, reviewed: info)

        // The rule that makes this safe to expose: a job that still runs
        // something present on this Mac is not a leftover and is never
        // removed, whoever is asking.
        guard PrivilegedJobRemoval.isDefunct(
            plist: contents,
            programExists: {
                var targetInfo = stat()
                if stat($0, &targetInfo) == 0 {
                    return true
                }
                let failure = errno
                return failure != ENOENT && failure != ENOTDIR
            }
        ) else {
            throw PrivilegedJobRemoval.Refusal.stillWorking
        }

        try await stopDeclaredJob(
            contents, directory: directory, path: target.path, requesterUID: requesterUID
        ) {
            try PrivilegedJobRemoval.validateReviewedEntry(parent: parent, name: name, reviewed: info)
        }
        try Task.checkCancellation()
        try PrivilegedJobRemoval.validateReviewedEntry(parent: parent, name: name, reviewed: info)
        try moveIntoQuarantine(parent: parent, name: name, from: directory)
    }

    private func stopDeclaredJob(
        _ contents: Data, directory: String, path: String, requesterUID: uid_t?, beforeStop: () throws -> Void
    ) async throws {
        if let dictionary = try? PropertyListSerialization.propertyList(
            from: contents, options: [], format: nil
        ) as? [String: Any], let label = dictionary["Label"] as? String {
            guard !label.isEmpty, !label.contains("/"), !label.contains("\0"),
                  !label.hasPrefix("com.apple."), let requesterUID, requesterUID != 0
            else {
                throw PrivilegedJobRemoval.Refusal.unreadable
            }
            let namespace = directory == "/Library/LaunchDaemons" ? "system" : "gui/\(requesterUID)"
            try await stopReviewedJob(label: label, namespace: namespace, path: path,
                                      contents: contents, beforeStop: beforeStop)
        } else {
            // Without a label no exact runtime check is possible. Preserve it.
            throw PrivilegedJobRemoval.Refusal.unreadable
        }
    }

    private func stopReviewedJob(
        label: String, namespace: String, path: String, contents: Data, beforeStop: () throws -> Void
    ) async throws {
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        func query(_ target: String) async throws -> NativeCommandRunner.Result {
            try await NativeCommandRunner.run(executable: "/bin/launchctl", arguments: ["print", target],
                                              environment: environment, timeout: 5)
        }
        guard try await query(namespace).termination == .exited(0) else {
            throw PrivilegedJobRemoval.Refusal.unreadable
        }
        let service = namespace + "/" + label
        let loaded = try await query(service)
        let diagnostic = (String(data: loaded.stderr, encoding: .utf8) ?? "")
        let serviceMissing = loaded.termination == .exited(113) && !loaded.outputTruncated
            && diagnostic.contains("Could not find service")
        if serviceMissing {
            return
        }
        guard loaded.termination == .exited(0), !loaded.outputTruncated,
              PrivilegedJobRemoval.loadedJobMatchesReviewedDefinition(
                  String(data: loaded.stdout, encoding: .utf8) ?? "",
                  reviewedPath: path, reviewedPlist: contents
              )
        else {
            throw PrivilegedJobRemoval.Refusal.unreadable
        }
        try beforeStop()
        let stopped = try await NativeCommandRunner.run(executable: "/bin/launchctl", arguments: ["bootout", service],
                                                        environment: environment, timeout: 5)
        guard stopped.termination == .exited(0) else { throw PrivilegedJobRemoval.Refusal.stillWorking }
        let after = try await query(service)
        guard after.termination == .exited(113), !after.outputTruncated,
              (String(data: after.stderr, encoding: .utf8) ?? "").contains("Could not find service")
        else {
            throw PrivilegedJobRemoval.Refusal.stillWorking
        }
    }

    /// Renames the file into the quarantine rather than unlinking it, so a
    /// mistake can be undone. Both directories are on the same volume, so
    /// this is one atomic rename and never a partial copy.
    /// Judged and moved through one descriptor for the folder, so a link
    /// swapped in after the check is not what moves.
    func setAsideBundle(_ target: URL) throws {
        let directory = target.deletingLastPathComponent().path
        let name = target.lastPathComponent
        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PrivilegedBundleRemoval.Refusal.notThere }
        defer { close(parent) }

        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PrivilegedBundleRemoval.Refusal.notThere
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw PrivilegedBundleRemoval.Refusal.notAFolder }
        try PrivilegedBundleRemoval.check(bundle: target)

        let holding = try openHoldingFolder(for: directory) { why in
            PrivilegedBundleRemoval.Refusal.couldNotQuarantine(why)
        }
        defer { close(holding) }
        guard renameat(parent, name, holding, name) == 0 else {
            throw PrivilegedBundleRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
    }

    /// A folder or a file, never a link, moved through the directory's own
    /// descriptor so nothing can be swapped in between the look and the move.
    func setAsideCache(_ target: URL) throws {
        let directory = target.deletingLastPathComponent().path
        let name = target.lastPathComponent
        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PrivilegedCacheRemoval.Refusal.notThere }
        defer { close(parent) }

        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PrivilegedCacheRemoval.Refusal.notThere
        }
        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG else { throw PrivilegedCacheRemoval.Refusal.isALink }

        let holding = try openHoldingFolder(for: directory) { why in
            PrivilegedCacheRemoval.Refusal.couldNotQuarantine(why)
        }
        defer { close(holding) }
        guard renameat(parent, name, holding, name) == 0 else {
            throw PrivilegedCacheRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
    }

    /// A regular file only, moved through the directory's own descriptor.
    func setAsidePreference(_ target: URL) throws {
        let directory = target.deletingLastPathComponent().path
        let name = target.lastPathComponent
        let parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PrivilegedPreferenceRemoval.Refusal.notThere }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PrivilegedPreferenceRemoval.Refusal.notThere
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw PrivilegedPreferenceRemoval.Refusal.notAFile }
        let holding = try openHoldingFolder(for: directory) { why in
            PrivilegedPreferenceRemoval.Refusal.couldNotQuarantine(why)
        }
        defer { close(holding) }
        guard renameat(parent, name, holding, name) == 0 else {
            throw PrivilegedPreferenceRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
    }

    private func moveIntoQuarantine(parent: Int32, name: String, from directory: String) throws {
        let holding = try openHoldingFolder(for: directory) { why in
            PrivilegedJobRemoval.Refusal.couldNotQuarantine(why)
        }
        defer { close(holding) }

        guard renameat(parent, name, holding, name) == 0 else {
            throw PrivilegedJobRemoval.Refusal.couldNotQuarantine(String(cString: strerror(errno)))
        }
    }
}
