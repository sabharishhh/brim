import CryptoKit
import Foundation

/// What the model has already said, so a release or a script is read once.
///
/// Keyed by a hash of the question, its inputs and the prompt's version,
/// so a changed prompt is a new question. Kept in Brim's caches folder,
/// because all of it can be asked again. Refusals are remembered for a day,
/// so a page that is opened often does not ask for the same refusal each
/// time.
struct IntelligenceCache {
    struct Entry: Codable {
        let value: Data
        let at: Date
    }

    struct Stored: Codable {
        var entries: [String: Entry] = [:]
        var refusals: [String: Date] = [:]
    }

    static let limit = 500
    static let refusalLifetime: TimeInterval = 24 * 60 * 60

    private let file: URL?
    private var stored: Stored

    init(file: URL?) {
        self.file = file
        stored = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    static func key(_ question: String, version: Int, _ inputs: String...) -> String {
        let joined = ([question, String(version)] + inputs).joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func value(for key: String) -> Data? {
        stored.entries[key]?.value
    }

    func refused(_ key: String, now: Date = Date()) -> Bool {
        stored.refusals[key].map { now.timeIntervalSince($0) < Self.refusalLifetime } ?? false
    }

    mutating func store(_ value: Data, for key: String, now: Date = Date()) {
        stored.entries[key] = Entry(value: value, at: now)
        stored.refusals[key] = nil
        if stored.entries.count > Self.limit {
            let oldest = stored.entries.sorted { $0.value.at < $1.value.at }.prefix(stored.entries.count - Self.limit)
            oldest.forEach { stored.entries[$0.key] = nil }
        }
        save()
    }

    mutating func markRefused(_ key: String, now: Date = Date()) {
        stored.refusals = stored.refusals.filter { now.timeIntervalSince($0.value) < Self.refusalLifetime }
        stored.refusals[key] = now
        save()
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
