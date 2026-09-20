import Foundation
@testable import BrimCore
import BrimScan

func run() async throws {
    let engine = EvidenceEngine(sources: [
        SandboxContainerSource(),
        BundleIdentifierComponentSource()
    ])
    let projector = FootprintProjector(engine: engine)
    let root = FileSystemRoot(rootURL: URL(fileURLWithPath: "/"))
    let identity = Identity(bundleID: "com.apple.Safari", name: "Safari")
    let fp = try await projector.project(identity: identity, in: root)
    print("Found \(fp.items.count) items, total bytes: \(fp.totalSizeBytes)")
    for item in fp.items {
        print(item.evidence.url.path)
    }
}
try await run()
