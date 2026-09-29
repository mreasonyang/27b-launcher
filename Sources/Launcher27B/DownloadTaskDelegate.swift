import Foundation

/// Streams an HTTP response directly into the partial file inside the app's
/// downloads directory.
///
/// Unlike `URLSessionDownloadTask`, the bytes land in a file we own as they arrive,
/// so a force-quit / SIGKILL / power-loss leaves a usable partial behind instead of
/// a reaped temp file. `resumeOffset` is the byte position this attempt starts at;
/// the server is asked for `Range: bytes=<resumeOffset>-` plus `If-Range:
/// <resumeValidator>` and the delegate validates the `206` response before appending:
/// it must start at the requested offset *and* carry the same validator, so an
/// object that changed underneath the partial cannot be spliced onto it.
final class DownloadTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destinationURL: URL
    private let resumeDataURL: URL
    private let requestedOffset: Int64
    private let resumeValidator: String?
    private let expectedByteCount: Int64

    private var continuation: CheckedContinuation<URL, Error>?
    private var completedResult: Result<URL, Error>?
    private var waitingForConnectivity = false
    private var fileHandle: FileHandle?
    private var writeOffset: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var failure: Error?
    /// Strong ETag of the response being
    /// streamed, persisted with the resume marker so the next attempt can prove the
    /// remote object is unchanged.
    private var responseValidator: String?
    private var receivedResponse = false
    /// Monotonic count of response/data callbacks, used by the downloader's stall
    /// watchdog to tell a slow-but-alive transfer from a wedged one.
    private var activityCount = 0

    init(
        destinationURL: URL,
        resumeDataURL: URL,
        resumeOffset: Int64 = 0,
        resumeValidator: String? = nil,
        expectedByteCount: Int64 = 0
    ) {
        self.destinationURL = destinationURL
        self.resumeDataURL = resumeDataURL
        self.requestedOffset = max(resumeOffset, 0)
        self.resumeValidator = resumeValidator
        self.expectedByteCount = expectedByteCount
        // Until the response arrives the partial already holds `resumeOffset` bytes, so
        // progress reporting and checkpointing start from there. A `200` response resets
        // this to zero in `prepareDestination`.
        self.writeOffset = max(resumeOffset, 0)
    }

    func attach(_ continuation: CheckedContinuation<URL, Error>) {
        let completed: Result<URL, Error>? = lock.withLock {
            if let completedResult {
                return completedResult
            }
            self.continuation = continuation
            return nil
        }

        if let completed {
            continuation.resume(with: completed)
        }
    }

    var isWaitingForConnectivity: Bool {
        lock.withLock { waitingForConnectivity }
    }

    /// Bytes persisted to `destinationURL` so far (base offset + this attempt).
    var persistedByteCount: Int64 {
        lock.withLock { max(writeOffset + receivedBytes, 0) }
    }

    /// Validator of the received response; before it arrives, the saved validator.
    ///
    /// The progress reporter persists this alongside the byte count once a second, so
    /// an abrupt exit leaves a partial that can be safely resumed with `If-Range`.
    var persistedValidator: String? {
        lock.withLock { receivedResponse ? responseValidator : resumeValidator }
    }

    /// Count of response/data callbacks observed so far; unchanged for
    /// `stallTimeout` seconds means the attempt is wedged.
    var activityCountSnapshot: Int {
        lock.withLock { activityCount }
    }

    /// Flushes buffered writes so a crash keeps as much of the partial as the OS allows.
    func synchronizeFile() throws {
        try lock.withLock { try fileHandle?.synchronize() }
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        taskIsWaitingForConnectivity task: URLSessionTask
    ) {
        lock.withLock {
            waitingForConnectivity = true
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let pending: (handle: FileHandle?, failure: Error?, persisted: Int64, validator: String?)
            = lock.withLock {
                waitingForConnectivity = false
                let handle = fileHandle
                fileHandle = nil
                return (
                    handle,
                    failure,
                    max(writeOffset + receivedBytes, 0),
                    receivedResponse ? responseValidator : resumeValidator
                )
            }

        do {
            try pending.handle?.synchronize()
            try pending.handle?.close()
            if let failure = pending.failure ?? error {
                if pending.persisted > 0 {
                    try persistResumeMarker(pending.persisted, validator: pending.validator)
                }
                complete(with: .failure(failure))
            } else {
                try ManagedFileSystem.removeIfPresent(resumeDataURL)
                complete(with: .success(destinationURL))
            }
        } catch { complete(with: .failure(error)) }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            fail(
                with: ArtifactDownloadError.invalidResponse,
                task: dataTask,
                completionHandler: completionHandler
            )
            return
        }
        lock.withLock { activityCount += 1 }

        // A 416 means the offset we asked for is past the end of the resource (the
        // remote file changed). Discard the partial and fetch it again from scratch.
        if httpResponse.statusCode == 416, requestedOffset > 0 {
            fail(
                with: DownloadRecoverySignal.restartFromZero,
                task: dataTask,
                completionHandler: completionHandler
            )
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            fail(
                with: RetryableHTTPError(
                    statusCode: httpResponse.statusCode,
                    retryAfterSeconds: Self.retryAfterSeconds(from: httpResponse)
                ),
                task: dataTask,
                completionHandler: completionHandler
            )
            return
        }

        // A captive portal answers with an HTML login page and 200; reject it before
        // gigabytes of markup land on disk and only fail later at checksum time.
        if Self.isHTMLErrorBody(httpResponse) {
            fail(
                with: ArtifactDownloadError.unexpectedContentType,
                task: dataTask,
                completionHandler: completionHandler
            )
            return
        }

        lock.withLock {
            receivedResponse = true
            responseValidator = Self.validator(from: httpResponse)
        }

        do {
            try prepareDestination(for: httpResponse)
            completionHandler(.allow)
        } catch {
            fail(with: error, task: dataTask, completionHandler: completionHandler)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let failure: Error? = lock.withLock {
            waitingForConnectivity = false
            activityCount += 1
            guard self.failure == nil, let handle = fileHandle else { return nil }
            do {
                try handle.write(contentsOf: data)
                receivedBytes += Int64(data.count)
                return nil
            } catch {
                let mapped = Self.mapWriteError(error)
                self.failure = mapped
                fileHandle = nil
                try? handle.close()
                return mapped
            }
        }

        if let failure {
            dataTask.cancel()
            complete(with: .failure(failure))
        }
    }

    // MARK: - Destination preparation

    private func prepareDestination(for response: HTTPURLResponse) throws {
        let targetOffset: Int64
        if response.statusCode == 206 {
            guard let start = Self.contentRangeStart(response), start == requestedOffset else {
                // The server answered from a different position than we asked for;
                // appending would corrupt the file, so restart cleanly.
                throw DownloadRecoverySignal.restartFromZero
            }
            if let requested = resumeValidator {
                guard let received = Self.validator(from: response) else {
                    // We asked `If-Range: <requested>` and the server answered 206
                    // without any strong `ETag`, so there is nothing to tie
                    // the slice to the bytes already on disk. A server that both
                    // ignores `If-Range` *and* omits validators would otherwise let
                    // two revisions be spliced together and reported as a success.
                    // Refuse the append and fetch the object again from zero.
                    throw DownloadRecoverySignal.restartFromZero
                }
                if requested != received {
                    // We asked `If-Range: <requested>` and still got a 206 carrying a
                    // different validator. `If-Range` was ignored, so the bytes after
                    // `requestedOffset` are not known to belong to the same object as the
                    // partial; restart instead of splicing two revisions together.
                    throw DownloadRecoverySignal.restartFromZero
                }
            }
            if let total = Self.contentRangeTotal(response),
               total > 0,
               expectedByteCount > 0,
               total != expectedByteCount {
                throw ArtifactDownloadError.unexpectedContentLength(
                    expected: expectedByteCount,
                    actual: total
                )
            }
            targetOffset = start
        } else {
            let contentLength = response.expectedContentLength
            if contentLength > 0, expectedByteCount > 0, contentLength != expectedByteCount {
                throw ArtifactDownloadError.unexpectedContentLength(
                    expected: expectedByteCount,
                    actual: contentLength
                )
            }
            // Server ignored our Range header; start the file over.
            targetOffset = 0
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: destinationURL.path) {
            guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
                throw ArtifactDownloadError.fileWriteFailed
            }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destinationURL)
        } catch {
            throw Self.mapWriteError(error)
        }

        let currentSize = try ManagedFileSystem.requiredFileSize(at: destinationURL)
        guard targetOffset <= currentSize else {
            try? handle.close()
            throw DownloadRecoverySignal.restartFromZero
        }

        do {
            try handle.truncate(atOffset: UInt64(targetOffset))
            try handle.seek(toOffset: UInt64(targetOffset))
        } catch {
            try? handle.close()
            throw Self.mapWriteError(error)
        }

        lock.withLock {
            writeOffset = targetOffset
            receivedBytes = 0
            fileHandle = handle
        }
    }

    // MARK: - Helpers

    private func fail(
        with error: Error,
        task: URLSessionTask,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let storedError: Error = lock.withLock {
            if failure == nil {
                failure = error
            }
            return failure ?? error
        }
        completionHandler(.cancel)
        task.cancel()
        complete(with: .failure(storedError))
    }

    private func complete(with result: Result<URL, Error>) {
        let continuation: CheckedContinuation<URL, Error>? = lock.withLock {
            completedResult = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func persistResumeMarker(_ bytes: Int64, validator: String?) throws {
        guard bytes > 0 else { return }
        try DownloadProgressCheckpoint().writeResumeMarker(
            DownloadProgressCheckpoint.ResumeMarker(bytes: bytes, validator: validator),
            to: resumeDataURL
        )
    }

    private static func mapWriteError(_ error: Error) -> Error {
        if FileSystemFailure.isOutOfSpace(error) {
            return ArtifactDownloadError.diskFull
        }
        return ArtifactDownloadError.fileWriteFailed
    }

    private static func isHTMLErrorBody(_ response: HTTPURLResponse) -> Bool {
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
        else {
            return false
        }
        return contentType.contains("text/html")
    }

    /// Only strong entity tags can prove that resumed bytes belong to one representation.
    /// RFC 9110 section 13.1.5 forbids weak tags in If-Range.
    static func validator(from response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespaces),
              value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        return value
    }

    /// Parses `Retry-After` and clamps it into
    /// `[DownloadRetryPolicy.minimumDelaySeconds, DownloadRetryPolicy.maximumDelaySeconds]`.
    ///
    /// Both ends matter: zero-delay retries can form a request loop, while a
    /// far-future date can otherwise keep a task asleep beyond a useful retry window.
    static func retryAfterSeconds(from response: HTTPURLResponse) -> Int? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces)
        else {
            return nil
        }
        if let seconds = Int(value) {
            return DownloadRetryPolicy.clampedDelay(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return DownloadRetryPolicy.clampedDelay(Int(date.timeIntervalSinceNow.rounded(.up)))
    }

    private static func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
              let bytesPart = range.split(separator: " ").last,
              let startPart = bytesPart.split(separator: "-").first
        else {
            return nil
        }
        return Int64(startPart)
    }

    private static func contentRangeTotal(_ response: HTTPURLResponse) -> Int64? {
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
              let totalPart = range.split(separator: "/").last,
              totalPart != "*"
        else {
            return nil
        }
        return Int64(totalPart)
    }

}
