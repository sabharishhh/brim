import AppKit
import Foundation
import IOKit.ps

/// macOS saying the battery, the temperature or Low Power Mode changed:
/// IOKit's power source notification and `ProcessInfo`, both pushed by the
/// system, so following them costs nothing. A stream lasts as long as the
/// task reading it.
public enum PowerEvents {
    public static func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let box = Unmanaged.passRetained(Relay(continuation))
            let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                Unmanaged<Relay>.fromOpaque(context).takeUnretainedValue().continuation.yield()
            }, box.toOpaque())?.takeRetainedValue()
            if let source {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            let center = NotificationCenter.default
            let observers = [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange]
                .map { center.addObserver(forName: $0, object: nil, queue: nil) { _ in continuation.yield() } }
            let installed = Installed(source: source, observers: observers)
            continuation.onTermination = { _ in
                DispatchQueue.main.async {
                    installed.remove()
                    box.release()
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

    /// What a stream installed, removed on the main thread it was added on.
    private final class Installed: @unchecked Sendable {
        let source: CFRunLoopSource?
        let observers: [any NSObjectProtocol]
        init(source: CFRunLoopSource?, observers: [any NSObjectProtocol]) {
            self.source = source
            self.observers = observers
        }

        func remove() {
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Whether any of Brim's windows can be seen: not hidden, minimised or
/// covered. Readings worth taking only for someone looking wait on this.
@MainActor
public enum AppVisibility {
    public static var isVisible: Bool {
        guard let app = NSApp else { return true }
        return !app.isHidden && app.occlusionState.contains(.visible)
    }
}
