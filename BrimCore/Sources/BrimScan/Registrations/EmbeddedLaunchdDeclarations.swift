import BrimCore
import Foundation

// swiftformat:disable wrapMultilineStatementBraces
/// Save embedded job labels before their host moves. This reads declarations,
/// not runtime state, and does not authorize stopping or removing a service.
enum EmbeddedLaunchdDeclarations {
    static func read(identity: Identity) -> RegistrationSnapshot {
        var records: [Registration] = []
        var complete = true
        let declarations = identity.capabilitySurface?.declarations.filter {
            $0.capability == .launchdJob && $0.key == "Label"
        } ?? []
        let host = identity.bundlePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        for declaration in declarations {
            let path = URL(fileURLWithPath: declaration.path).standardizedFileURL
            let parent = path.deletingLastPathComponent().path
            let daemon = parent.hasSuffix(".app/Contents/Library/LaunchDaemons")
            let agent = parent.hasSuffix(".app/Contents/Library/LaunchAgents")
            guard daemon || agent else { continue }
            guard let host, path.path.hasPrefix(host + "/"),
                  path.resolvingSymlinksInPath().path.hasPrefix(host + "/") else {
                complete = false
                continue
            }
            let presence = PathObservation.observe(path.path)
            if presence.isAbsent {
                continue
            }
            guard presence.isPresent,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
                  let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024,
                  let job = try? LaunchdJobDefinition.read(path.path), job.label == declaration.value else {
                complete = false
                continue
            }
            let program = job.resolvedProgram(plistPath: path.path)
            let target = PathObservation.observe(program, followingLinks: true)
            records.append(Registration(
                kind: .launchdJob, identifier: job.label, label: job.label,
                owningBundleID: identity.bundleID, programPath: program,
                targetExists: target.isPresent, recordPath: path.path,
                evidence: "Declared inside the application bundle; runtime state is checked separately.",
                targetPresence: target, namespace: daemon ? "system" : "gui/\(getuid())",
                runtimeState: "declared"
            ))
        }
        return RegistrationSnapshot(registrations: records, coverage: complete
            ? .available(.launchdJob)
            : .unavailable(.launchdJob, "An embedded background job could not be checked."), readerVersion: 2)
    }
}
