import CryptoKit
import Foundation

/// A download with progress, into a folder Brim owns.
///
/// A connection that drops is picked up where it stopped: the partial
/// download's resume data is kept per address, used on the next attempt,
/// and two attempts are made on their own before the update is reported as
/// failed. A server that will not resume starts again from nothing.
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: UpdateInstaller.Progress
    private let folder: URL
    private let resumeFile: URL
    private var continuation: CheckedContinuation<URL, Error>?

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
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let resumeFile = resumeFolder.appendingPathComponent(key)
        var lastError: Error = UpdateInstaller.Failure.download("It did not start.")
        for attempt in 0 ..< 3 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            let downloader = UpdateDownloader(folder: folder, resumeFile: resumeFile, progress: progress)
            let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let file = try await withCheckedThrowingContinuation { continuation in
                    downloader.continuation = continuation
                    if let data = try? Data(contentsOf: resumeFile) {
                        session.downloadTask(withResumeData: data).resume()
                    } else {
                        session.downloadTask(with: url).resume()
                    }
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

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            try? FileManager.default.removeItem(at: resumeFile)
            continuation?.resume(throwing: UpdateInstaller.Failure.download("The server answered \(status)."))
            continuation = nil
            return
        }
        let name = downloadTask.response?.suggestedFilename ?? "download"
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if let resume {
            try? resume.write(to: resumeFile, options: .atomic)
        } else {
            // Resume data that did not work is not tried twice.
            try? FileManager.default.removeItem(at: resumeFile)
        }
        continuation?.resume(throwing: UpdateInstaller.Failure.download(error.localizedDescription))
        continuation = nil
    }
}
