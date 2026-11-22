import Foundation

/// Downloads an engine artifact to a local file. Injected so tests never touch the network.
public protocol EngineDownloader: Sendable {
    /// Downloads `url` into `destination` (which must not exist yet).
    /// `progress` receives a fraction in `0...1` when the size is known.
    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

public enum EngineDownloadError: Error, Equatable, LocalizedError {
    case insecureURL(URL)
    case httpStatus(Int)
    case noFile

    public var errorDescription: String? {
        switch self {
        case .insecureURL(let url): coreLocalized("Refusing to download over an insecure connection: \(url.absoluteString)")
        case .httpStatus(let code): coreLocalized("The server responded with HTTP status \(code).")
        case .noFile: coreLocalized("The download finished without a file.")
        }
    }
}

/// Production downloader backed by `URLSession`. Only HTTPS is allowed.
public struct URLSessionEngineDownloader: EngineDownloader {
    public init() {}

    public func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard url.scheme?.lowercased() == "https" else { throw EngineDownloadError.insecureURL(url) }

        let delegate = EngineDownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(session.downloadTask(with: url), continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

final class EngineDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var outcome: Result<Void, Error>?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    private var isCancelled = false

    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
        let alreadyCancelled = lock.withLock { () -> Bool in
            self.task = task
            self.continuation = continuation
            return self.isCancelled
        }
        if alreadyCancelled { task.cancel() }
        task.resume()
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            self.isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        self.progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, url.scheme?.lowercased() == "https" else {
            let error = request.url.map(EngineDownloadError.insecureURL) ?? .noFile
            self.lock.withLock { self.outcome = .failure(error) }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func validateResponse(_ response: URLResponse?) throws {
        guard let url = response?.url else { throw EngineDownloadError.noFile }
        guard url.scheme?.lowercased() == "https" else { throw EngineDownloadError.insecureURL(url) }
        guard let http = response as? HTTPURLResponse else { throw EngineDownloadError.noFile }
        guard (200..<300).contains(http.statusCode) else { throw EngineDownloadError.httpStatus(http.statusCode) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Returning nil from the redirect delegate can deliver the original redirect
        // response here. Preserve the specific rejection and leave its file untouched.
        guard self.lock.withLock({ self.outcome == nil }) else { return }
        let result = Result {
            try Self.validateResponse(downloadTask.response)
            // The temporary file is deleted when this method returns.
            try FileManager.default.moveItem(at: location, to: self.destination)
        }
        self.lock.withLock { self.outcome = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, outcome) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Result<Void, Error>?) in
            defer { self.continuation = nil }
            return (self.continuation, self.outcome)
        }
        if case .failure(let failure)? = outcome {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(with: outcome ?? .failure(EngineDownloadError.noFile))
        }
    }
}
