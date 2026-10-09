import BrimCore
import CryptoKit
import Foundation

// swiftformat:disable wrapMultilineStatementBraces

/// A download with progress, into a folder Brim owns.
///
/// A connection that drops is picked up where it stopped: the partial
/// download's resume data is kept per address, used on the next attempt,
/// and two attempts are made on their own before the update is reported as
/// failed. A server that will not resume starts again from nothing.
///
/// Cancelling the task that asked keeps what has arrived the same way, so
/// pressing Update again carries on from there. What is kept for resuming
/// is deleted once it is a day old (`resumeLifetime`), with the partial file
/// URLSession holds for it, so a cancelled download does not sit in the
/// temporary folder forever.
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// How long a stopped download is kept for resuming.
    static let resumeLifetime: TimeInterval = 24 * 60 * 60

    private let progress: UpdateInstaller.Progress
    private let folder: URL
    private let resumeFile: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var isCancelled = false

    private init(folder: URL, resumeFile: URL, progress: @escaping UpdateInstaller.Progress) {
        self.folder = folder
        self.resumeFile = resumeFile
        self.progress = progress
    }

    static func fetch(
        _ url: URL, into folder: URL, resumeFolder: URL, progress: @escaping UpdateInstaller.Progress
    ) async throws -> URL {
        guard url.scheme == "https" else { throw UpdateInstaller.Failure.download("It is not an HTTPS address.") }
        try? FileManager.default.createDirectory(at: resumeFolder, withIntermediateDirectories: true)
        discardExpired(in: resumeFolder)
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let resumeFile = resumeFolder.appendingPathComponent(key)
        var lastError: Error = UpdateInstaller.Failure.download("It did not start.")
        for attempt in 0 ..< 3 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            try Task.checkCancellation()
            let downloader = UpdateDownloader(folder: folder, resumeFile: resumeFile, progress: progress)
            let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let file = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let task = (try? Data(contentsOf: resumeFile)).map { session.downloadTask(withResumeData: $0) }
                            ?? session.downloadTask(with: url)
                        downloader.start(task, continuation: continuation)
                    }
                } onCancel: {
                    downloader.cancel()
                }
                try? FileManager.default.removeItem(at: resumeFile)
                return file
            } catch let error as UpdateInstaller.Failure {
                lastError = error
                // A server answer, not a dropped connection: no point asking again.
                if case let .download(why) = error, why.hasPrefix("The server answered") {
                    throw error
                }
            }
        }
        throw lastError
    }

    private func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        self.task = task
        let stopped = isCancelled
        lock.unlock()
        if stopped {
            finish(.failure(CancellationError()))
        } else {
            task.resume()
        }
    }

    /// Stops the download and keeps what arrived for the next attempt.
    private func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel(byProducingResumeData: { [resumeFile] data in
            try? data?.write(to: resumeFile, options: .atomic)
        })
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    /// Resume data a day old, and the partial file it points to.
    static func discardExpired(in resumeFolder: URL, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: resumeFolder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files {
            let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if now.timeIntervalSince(written ?? .distantPast) > resumeLifetime {
                discard(file)
            }
        }
    }

    /// Deletes resume data and the partial download URLSession kept for it
    /// in the temporary folder, which deleting the resume data alone leaves.
    static func discard(_ resumeFile: URL) {
        if let data = try? Data(contentsOf: resumeFile),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            let temporary = FileManager.default.temporaryDirectory
            let named = (info["NSURLSessionResumeInfoTempFileName"] as? String)
                .map { temporary.appendingPathComponent($0).path }
            let partials = [info["NSURLSessionResumeInfoLocalPath"] as? String, named].compactMap(\.self)
            // Only a file in the temporary folder, whatever the data says.
            for path in partials where URL(fileURLWithPath: path).standardizedFileURL.path
                .hasPrefix(temporary.standardizedFileURL.path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        try? FileManager.default.removeItem(at: resumeFile)
    }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(DownloadProgress(received: totalBytesWritten, expected: totalBytesExpectedToWrite))
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            Self.discard(resumeFile)
            finish(.failure(UpdateInstaller.Failure.download("The server answered \(status).")))
            return
        }
        let name = downloadTask.response?.suggestedFilename ?? "download"
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        // Stopped on purpose: the resume data is written by the cancel.
        if (error as NSError).code == NSURLErrorCancelled {
            lock.lock()
            let stopped = isCancelled
            lock.unlock()
            if stopped {
                finish(.failure(CancellationError()))
                return
            }
        }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if let resume {
            try? resume.write(to: resumeFile, options: .atomic)
        } else {
            // Resume data that did not work is not tried twice.
            Self.discard(resumeFile)
        }
        finish(.failure(UpdateInstaller.Failure.download(error.localizedDescription)))
    }
}
