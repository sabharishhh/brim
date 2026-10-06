import BrimCore
import Foundation

/// Where recordings are kept: the first snapshot of one under way, so it
/// survives Brim quitting while something installs, and the recordings the
/// person kept.
public actor InstallRecordingStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var activeURL: URL {
        directory.appendingPathComponent("active.json")
    }

    var keptURL: URL {
        directory.appendingPathComponent("recordings.json")
    }

    func saveActive(_ snapshot: InstallSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: activeURL, options: .atomic)
    }

    func active() -> InstallSnapshot? {
        guard let data = try? Data(contentsOf: activeURL) else { return nil }
        return try? JSONDecoder().decode(InstallSnapshot.self, from: data)
    }

    func clearActive() {
        try? FileManager.default.removeItem(at: activeURL)
    }

    func keep(_ recording: InstallRecording) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let all = Self.load(keptURL).filter { $0.id != recording.id } + [recording]
        try JSONEncoder().encode(all).write(to: keptURL, options: .atomic)
    }

    func recordings() -> [InstallRecording] {
        Self.load(keptURL)
    }

    /// Read without the actor, for the evidence source, which runs inside a
    /// search that cannot wait on it.
    public nonisolated static func load(_ url: URL) -> [InstallRecording] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([InstallRecording].self, from: data)) ?? []
    }
}
