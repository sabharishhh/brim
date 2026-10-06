import Foundation

/// Revalidates Homebrew's catalogue once per requested check, only when an
/// application needs it. An ETag lets the publisher confirm unchanged data
/// without downloading the whole catalogue again.
actor CatalogueCache {
    private let directory: URL
    private let fetch: UpdateFinder.Fetch
    private var loading: Task<[CatalogCask]?, Never>?
    static let source = URL(string: "https://formulae.brew.sh/api/cask.json")!

    init(directory: URL, fetch: @escaping UpdateFinder.Fetch) {
        self.directory = directory
        self.fetch = fetch
    }

    /// One load, shared. Applications ask at the same time, and an actor
    /// lets the second one in while the first is waiting on the network:
    /// a flag set before the download told every other application there
    /// was no catalogue.
    func casks() async -> [CatalogCask]? {
        if let loading {
            return await loading.value
        }
        let task = Task { await load() }
        loading = task
        return await task.value
    }

    private func load() async -> [CatalogCask]? {
        let file = directory.appendingPathComponent("cask.json")
        let tag = directory.appendingPathComponent("cask.etag")
        let cached = (try? Data(contentsOf: file)).map(HomebrewCatalog.casks)
            .flatMap { $0.isEmpty ? nil : $0 }
        var request = URLRequest(url: Self.source, cachePolicy: .reloadIgnoringLocalCacheData)
        if cached != nil, let etag = try? String(contentsOf: tag, encoding: .utf8), !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, response) = try? await fetch(request) else { return nil }
        if response.statusCode == 304 {
            guard request.value(forHTTPHeaderField: "If-None-Match") != nil else { return nil }
            return cached
        }
        guard response.statusCode == 200 else { return nil }
        let casks = HomebrewCatalog.casks(from: data)
        guard !casks.isEmpty else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            // A new response without an ETag cannot keep the old representation's tag.
            let etag = response.value(forHTTPHeaderField: "ETag") ?? ""
            try etag.write(to: tag, atomically: true, encoding: .utf8)
        } catch {
            // The response remains usable even when it cannot be persisted.
        }
        return casks
    }
}
