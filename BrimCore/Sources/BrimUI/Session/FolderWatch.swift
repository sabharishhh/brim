import CoreServices
import Foundation

/// macOS saying something changed in a set of folders. File system events
/// cost nothing while nothing changes, and with a two second latency a large
/// copy arrives as one event. A stream lasts as long as the task reading
/// it, so nothing watches once Brim has quit.
public enum FolderWatch {
    public static func changes(in folders: [URL], latency: TimeInterval = 2) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let relay = Unmanaged.passRetained(Relay(continuation))
            var context = FSEventStreamContext(
                version: 0, info: relay.toOpaque(), retain: nil, release: nil, copyDescription: nil
            )
            let paths = folders.map(\.path) as CFArray
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            guard let stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue().continuation.yield()
            }, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
                relay.release()
                continuation.finish()
                return
            }
            let queue = DispatchQueue(label: "com.sabharishhh.brim.folder-watch")
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            let running = Running(stream: stream)
            continuation.onTermination = { _ in
                queue.async {
                    running.stop()
                    relay.release()
                }
            }
        }
    }

    private final class Relay: @unchecked Sendable {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) {
            self.continuation = continuation
        }
    }

    private final class Running: @unchecked Sendable {
        let stream: FSEventStreamRef
        init(stream: FSEventStreamRef) {
            self.stream = stream
        }

        func stop() {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// What the Applications folders hold, cheap enough to ask after every
/// event: each bundle's path, folder identity and `Info.plist` time. Opening
/// an app is an event in the folder too, so the apps are listed again only
/// when this answer changes, not each time an app opens.
public enum ApplicationFolders {
    public static var standard: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    public static func signature(of folders: [URL] = standard) -> [String: String] {
        var found: [String: String] = [:]
        for folder in folders {
            for name in entries(folder.path) {
                let path = folder.path + "/" + name
                if name.hasSuffix(".app") {
                    found[path] = mark(path)
                } else if isFolder(path) {
                    for inner in entries(path) where inner.hasSuffix(".app") {
                        found[path + "/" + inner] = mark(path + "/" + inner)
                    }
                }
            }
        }
        return found
    }

    private static func entries(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    private static func isFolder(_ path: String) -> Bool {
        var status = stat()
        return stat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    private static func mark(_ bundle: String) -> String {
        var root = stat()
        var info = stat()
        _ = lstat(bundle, &root)
        _ = stat(bundle + "/Contents/Info.plist", &info)
        return "\(root.st_ino)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }
}
