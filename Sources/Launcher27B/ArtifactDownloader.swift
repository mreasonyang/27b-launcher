import Foundation

struct ArtifactDownloader: Sendable {
    /// Headroom kept free on the download volume while streaming, so the app fails with
    /// a clear message instead of a raw `ENOSPC` deep into a multi-hour download.
    static let diskSpaceReserveBytes: Int64 = 268_435_456
    private static let diskSpaceCheckInterval: Duration = .seconds(10)

    /// Default for ``attemptStallTimeoutSeconds``: the longest silence a live attempt
    /// may show before it is treated as wedged.
    ///
    /// Exposed so the value is a documented, assertable product decision rather than a
    /// literal buried in an initialiser. See the property below for the justification.
    static let defaultAttemptStallTimeoutSeconds = 120

    private let retryDelaysSeconds: [Int]
    /// How long an attempt may go without a response/data callback before it is
    /// treated as wedged and cancelled. `timeoutIntervalForRequest` alone does not
    /// bound an endpoint that completes the TCP handshake and then stalls (a captive
    /// portal, a stalled proxy/CDN edge, a wedged origin): a URLSession data task
    /// with `waitsForConnectivity` can sit there indefinitely, so the retry cap in
    /// ``DownloadRetryPolicy`` was unreachable. Cancelling the task does make the
    /// delegate completion fire, which hands control back to the retry loop.
    ///
    /// The default is deliberately larger than `timeoutIntervalForRequest`: this is an
    /// *inactivity* bound, i.e. the longest total silence a live transfer may show.
    /// A congested or roaming link can legitimately pause body delivery for a minute
    /// without being dead, so the tolerance is 120 s — twice the request timeout the
    /// app used before, and far below the minutes a genuinely wedged socket would
    /// otherwise hang the UI. Any callback — headers *or* a data chunk — resets it, so
    /// a slow-but-progressing transfer is never mistaken for a stalled one.
    private let attemptStallTimeoutSeconds: Int
    /// Test seam: when non-nil, replaces the delegate's connectivity-parked state for
    /// the stall watchdog and the progress reporter.
    ///
    /// Production leaves this `nil` and the real `URLSessionTaskDelegate` callback is
    /// used. A unit test cannot take a real network path down (and must not), so this
    /// is how the `.isWaitingForConnectivity → .notConnectedToInternet` mapping — and
    /// the far longer offline retry budget it selects — is exercised.
    private let connectivityWaitOverride: (@Sendable () -> Bool)?
    private let checkpoint = DownloadProgressCheckpoint()

    init(
        retryDelaysSeconds: [Int] = [1, 2, 4, 8, 15],
        attemptStallTimeoutSeconds: Int = ArtifactDownloader.defaultAttemptStallTimeoutSeconds,
        connectivityWaitOverride: (@Sendable () -> Bool)? = nil
    ) {
        self.retryDelaysSeconds = retryDelaysSeconds
        self.attemptStallTimeoutSeconds = attemptStallTimeoutSeconds
        self.connectivityWaitOverride = connectivityWaitOverride
    }

    /// Downloads `artifact` into `destinationURL`.
    ///
    /// Bytes are streamed into `destinationURL` itself (inside the app's downloads
    /// directory), so a force-quit mid-download leaves a resumable partial. The next
    /// call resumes with `Range: bytes=<offset>-`, where `<offset>` is the durable
    /// checkpoint; a checkpoint beyond the on-disk size is rejected. The byte count *and* the HTTP
    /// validator of the partial's remote object are rewritten once a second while the
    /// transfer runs, so a SIGKILL / power loss (no completion callback at all) still
    /// leaves both on disk; `resumeDataURL` is the same payload kept as a lightweight
    /// "download in progress" marker.
    ///
    /// A resume is only attempted when that validator is known: it is sent back as
    /// `If-Range`, so a publisher re-uploading the artifact at the same URL makes the
    /// server answer `200` and the download restart from zero instead of splicing the
    /// new content onto the stale prefix. With no stored validator the download also
    /// restarts from zero, because the bytes on disk cannot be proven to belong to
    /// what the server is serving now.
    ///
    /// Retrying is bounded by ``DownloadRetryPolicy`` — both the retry count and each
    /// attempt's inactivity — so `download()` always returns: the call throws instead
    /// of retrying forever, including against an endpoint that accepts connections and
    /// then never answers.
    func download(
        artifact: InstallationArtifact,
        to destinationURL: URL,
        resumeDataURL: URL,
        progressDataURL: URL,
        progress: @escaping @Sendable (ArtifactDownloadUpdate) async -> Void
    ) async throws -> URL {
        var retryAttempt = 0
        var restartAttempt = 0
        var retryElapsed: Duration = .zero

        while true {
            try Task.checkCancellation()
            var resumeOffset = try checkpoint.resumeOffset(
                partialURL: destinationURL,
                progressDataURL: progressDataURL,
                expectedByteCount: artifact.expectedByteCount
            )
            var resumeValidator: String?
            if resumeOffset > 0 {
                let progressState = try checkpoint.readResumeMarker(from: progressDataURL)
                resumeValidator = progressState.validator
                if resumeValidator == nil {
                    // The bytes on disk cannot be tied to the remote object: a crash before the
                    // first progress tick. Resuming would splice whatever the server
                    // serves now onto the stale prefix and report success, so start
                    // over instead.
                    resumeOffset = 0
                }
            }
            if resumeOffset == 0 {
                try checkpoint.remove(at: progressDataURL)
                try checkpoint.remove(at: resumeDataURL)
            }

            do {
                return try await performDownload(
                    artifact: artifact,
                    to: destinationURL,
                    resumeDataURL: resumeDataURL,
                    progressDataURL: progressDataURL,
                    resumeOffset: resumeOffset,
                    resumeValidator: resumeValidator,
                    progress: progress
                )
            } catch {
                if try handleFailedAttempt(
                    error,
                    destinationURL: destinationURL,
                    progressDataURL: progressDataURL,
                    resumeDataURL: resumeDataURL
                ) {
                    // The server answered from a different position than requested;
                    // start over cleanly rather than risk appending at the wrong offset.
                    restartAttempt += 1
                    guard restartAttempt <= 3 else {
                        throw ArtifactDownloadError.invalidResponse
                    }
                    continue
                }
                if error is CancellationError
                    || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                if Task.isCancelled {
                    throw CancellationError()
                }

                guard Self.isRetryable(error) else {
                    throw Self.userFacingError(for: error)
                }

                // Bounded budget: without this a permanently-failing endpoint (or a
                // captive portal) kept the loop, and the UI, alive indefinitely. The
                // offline/captive-portal class gets a far longer budget than a broken
                // server, because the user can fix it without touching the app.
                let budget = Self.retryBudget(for: error)
                guard retryAttempt < budget.attempts,
                      retryElapsed < .seconds(budget.elapsedSeconds)
                else {
                    throw Self.retryExhaustedError(for: error, attempts: retryAttempt)
                }

                let delay = Self.retryDelaySeconds(
                    for: error,
                    attempt: retryAttempt,
                    scheduledDelays: retryDelaysSeconds
                )
                retryAttempt += 1
                retryElapsed += .seconds(delay)
                let savedBytes = try checkpoint.resumeOffset(
                    partialURL: destinationURL,
                    progressDataURL: progressDataURL,
                    expectedByteCount: artifact.expectedByteCount
                )
                await progress(
                    ArtifactDownloadUpdate(
                        completedBytes: min(savedBytes, artifact.expectedByteCount),
                        totalBytes: artifact.expectedByteCount,
                        state: .waitingForNetwork(
                            retryAttempt: retryAttempt,
                            retryAfterSeconds: delay
                        ),
                        bytesPerSecond: nil,
                        estimatedTimeRemaining: nil
                    )
                )
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func performDownload(
        artifact: InstallationArtifact,
        to destinationURL: URL,
        resumeDataURL: URL,
        progressDataURL: URL,
        resumeOffset: Int64,
        resumeValidator: String?,
        progress: @escaping @Sendable (ArtifactDownloadUpdate) async -> Void
    ) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        // Kept equal to the stall watchdog below: the two are the same "silence"
        // tolerance seen from two layers, and letting the watchdog fire first would
        // only replace a real `URLError.timedOut` with a synthesised one.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7

        var request = URLRequest(url: artifact.downloadURL)
        request.timeoutInterval = 120
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            if let resumeValidator {
                // If the remote object changed, the server MUST ignore the Range and
                // answer 200; the delegate then truncates and starts over.
                request.setValue(resumeValidator, forHTTPHeaderField: "If-Range")
            }
        }

        let delegate = DownloadTaskDelegate(
            destinationURL: destinationURL,
            resumeDataURL: resumeDataURL,
            resumeOffset: resumeOffset,
            resumeValidator: resumeValidator,
            expectedByteCount: artifact.expectedByteCount
        )
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let task = session.dataTask(with: request)
        let isResuming = resumeOffset > 0
        let savedBytes = min(max(resumeOffset, 0), artifact.expectedByteCount)
        let attemptAbort = DownloadAbortBox()
        // The delegate's real connectivity state, or the test seam's stand-in for it.
        let connectivityWaitOverride = self.connectivityWaitOverride
        let isParkedOnConnectivity: @Sendable () -> Bool = connectivityWaitOverride
            ?? { delegate.isWaitingForConnectivity }

        let progressReporter = Task {
            let clock = ContinuousClock()
            var sampleInstant = clock.now
            var sampleBytes = savedBytes
            var smoothedSpeed: Double?
            var lastCheckpointInstant = sampleInstant
            var lastDiskCheckInstant = sampleInstant
            let stallTimeout = Duration.seconds(max(attemptStallTimeoutSeconds, 1))
            var lastActivity = delegate.activityCountSnapshot
            var lastActivityInstant = sampleInstant

            do {
                while !Task.isCancelled {
                    let now = clock.now
                    // `persistedByteCount` already accounts for the resume offset, and drops
                    // back to zero when the server ignores the Range request.
                    let completed = min(
                        max(delegate.persistedByteCount, 0),
                        artifact.expectedByteCount
                    )
                    let elapsed = sampleInstant.duration(to: now)
                    if elapsed >= .milliseconds(750), completed > sampleBytes {
                        let seconds = Double(elapsed.components.seconds)
                            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
                        if seconds > 0 {
                            let instantaneous = Double(completed - sampleBytes) / seconds
                            smoothedSpeed = smoothedSpeed.map { $0 * 0.7 + instantaneous * 0.3 }
                                ?? instantaneous
                        }
                        sampleInstant = now
                        sampleBytes = completed
                    }

                    if lastCheckpointInstant.duration(to: now) >= .seconds(1), completed > 0 {
                        // Persist the validator alongside the byte count: this path runs
                        // while the transfer is alive, so it is what survives a SIGKILL /
                        // power loss that never reaches `didCompleteWithError`.
                        let marker = DownloadProgressCheckpoint.ResumeMarker(
                            bytes: completed,
                            validator: delegate.persistedValidator
                        )
                        try delegate.synchronizeFile()
                        try checkpoint.writeResumeMarker(marker, to: progressDataURL)
                        if marker.validator != nil {
                            try checkpoint.writeResumeMarker(marker, to: resumeDataURL)
                        }
                        lastCheckpointInstant = now
                    }

                    // Bound a wedged attempt: an endpoint that accepts the connection and
                    // then never answers produces no delegate callback at all, so without
                    // this the retry cap was unreachable and the UI hung forever. Any
                    // response/data callback counts as activity; cancelling makes the
                    // completion fire and hands the failure to the retry loop.
                    let activity = delegate.activityCountSnapshot
                    if activity != lastActivity {
                        lastActivity = activity
                        lastActivityInstant = now
                    } else if !Task.isCancelled,
                              lastActivityInstant.duration(to: now) >= stallTimeout {
                        // A task parked on connectivity is the offline/captive-portal
                        // case: report it as such so the retry loop uses the offline
                        // budget instead of the short broken-server one, which is what
                        // lets a dropped network self-heal.
                        //
                        // This is a *bounded* wait, not an indefinite one: the offline
                        // budget allows `DownloadRetryPolicy.offlineMaximumAttempts`
                        // parked attempts of up to `attemptStallTimeoutSeconds` each
                        // (~40 minutes in total), after which `download()` returns and
                        // the UI stops waiting for the user to reconnect.
                        if isParkedOnConnectivity() {
                            attemptAbort.record(URLError(.notConnectedToInternet))
                        } else {
                            attemptAbort.record(URLError(.timedOut))
                        }
                        task.cancel()
                    }

                    if lastDiskCheckInstant.duration(to: now) >= Self.diskSpaceCheckInterval {
                        lastDiskCheckInstant = now
                        if try Self.isDiskSpaceExhausted(
                            at: destinationURL,
                            remainingBytes: max(artifact.expectedByteCount - completed, 0),
                            expectedByteCount: artifact.expectedByteCount
                        ) {
                            attemptAbort.record(ArtifactDownloadError.diskFull)
                            task.cancel()
                        }
                    }

                    let remaining = max(artifact.expectedByteCount - completed, 0)
                    let eta = smoothedSpeed.flatMap { speed in
                        speed > 0 ? Double(remaining) / speed : nil
                    }
                    await progress(
                        ArtifactDownloadUpdate(
                            completedBytes: completed,
                            totalBytes: artifact.expectedByteCount,
                            state: isParkedOnConnectivity()
                                ? .waitingForNetwork(retryAttempt: 0, retryAfterSeconds: 0)
                                : .downloading(isResuming: isResuming),
                            bytesPerSecond: smoothedSpeed,
                            estimatedTimeRemaining: eta
                        )
                    )
                    do { try await Task.sleep(for: .milliseconds(250)) }
                    catch is CancellationError { return }
                }
            } catch {
                attemptAbort.record(error)
                task.cancel()
            }
        }

        let downloadedURL: URL
        do {
            downloadedURL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.attach(continuation)
                    task.resume()
                }
            } onCancel: {
                // The partial file on disk is the resume state; no URLSession resume
                // payload is needed for a force-quit-safe restart.
                task.cancel()
            }
        } catch {
            progressReporter.cancel()
            await progressReporter.value
            if let abortError = attemptAbort.error { throw abortError }
            let persisted = min(
                max(delegate.persistedByteCount, 0),
                artifact.expectedByteCount
            )
            let marker = DownloadProgressCheckpoint.ResumeMarker(
                bytes: persisted,
                validator: delegate.persistedValidator
            )
            try checkpoint.writeResumeMarker(marker, to: progressDataURL)
            if marker.validator != nil {
                try checkpoint.writeResumeMarker(marker, to: resumeDataURL)
            }
            throw error
        }

        progressReporter.cancel()
        await progressReporter.value
        if let abortError = attemptAbort.error { throw abortError }

        guard let response = task.response as? HTTPURLResponse else {
            throw ArtifactDownloadError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.httpStatusError(for: response)
        }

        if artifact.expectedByteCount > 0,
           try Self.fileSize(at: downloadedURL) != artifact.expectedByteCount {
            // Keep the partial and its checkpoint; the retry loop resumes with Range.
            throw ArtifactDownloadError.incompleteDownload
        }

        try checkpoint.remove(at: resumeDataURL)
        try checkpoint.remove(at: progressDataURL)
        await progress(
            ArtifactDownloadUpdate(
                completedBytes: artifact.expectedByteCount,
                totalBytes: artifact.expectedByteCount,
                state: .downloading(isResuming: isResuming),
                bytesPerSecond: nil,
                estimatedTimeRemaining: 0
            )
        )
        return downloadedURL
    }

    // MARK: - Retry classification

    /// 5xx/429 responses and connection-level/TLS failures are worth retrying.
    /// A captive portal on hotel/airport Wi-Fi shows up as a secure-connection
    /// failure, so those recover automatically once the user logs in.
    static func isRetryable(_ error: Error) -> Bool {
        if let retryable = error as? RetryableHTTPError {
            return retryable.statusCode == 429
                || (500...599).contains(retryable.statusCode)
        }
        if let downloadError = error as? ArtifactDownloadError {
            return downloadError == .incompleteDownload
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .dataNotAllowed,
             .internationalRoamingOff,
             .timedOut,
             .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }

    /// Whether a failed attempt invalidates the bytes already on disk.
    ///
    /// Only content-position signals do: the server answered from a different byte
    /// position, or rejected the requested `Range` (416); both surface as
    /// `DownloadRecoverySignal.restartFromZero`. Transport, TLS, HTTP-status and
    /// redirect failures say nothing about the bytes on disk — in particular
    /// `NSURLErrorRedirectToNonExistentLocation` (-1010), which an earlier revision
    /// misread as "cannot resume" and answered by deleting an hours-long partial.
    static func discardsPartialFile(for error: Error) -> Bool {
        (error as? DownloadRecoverySignal) == .restartFromZero
    }

    /// Applies the on-disk side effects of a failed attempt.
    ///
    /// Returns `true` when the failure invalidates the bytes already on disk, so the
    /// caller restarts from zero. This is deliberately the *deletion site* itself, not
    /// just the classifier: a test can seed a partial and assert that a redirect
    /// failure (-1010) or any other transport error leaves it untouched, which cannot
    /// be proven by calling ``discardsPartialFile(for:)`` in isolation.
    @discardableResult
    func handleFailedAttempt(
        _ error: Error,
        destinationURL: URL,
        progressDataURL: URL,
        resumeDataURL: URL
    ) throws -> Bool {
        guard Self.discardsPartialFile(for: error) else { return false }
        try ManagedFileSystem.removeIfPresent(destinationURL)
        try checkpoint.remove(at: progressDataURL)
        try checkpoint.remove(at: resumeDataURL)
        return true
    }

    /// Whether a failure is the offline/captive-portal class the user can clear by
    /// joining the network or signing in to the portal.
    ///
    /// Distinct from a broken server: the loop waits far longer for these, because no
    /// amount of retrying "fixes" a 503 but a portal login does fix a TLS failure.
    /// A mid-transfer `networkConnectionLost` is deliberately *not* in this class: data
    /// was flowing and the endpoint is reachable, so the ordinary retry budget applies
    /// (and, for a body the server keeps truncating, gives up in seconds, not minutes).
    static func isOfflineCondition(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .dataNotAllowed,
             .internationalRoamingOff,
             .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }

    /// Retry budget for a failure. The offline/captive-portal class is allowed to wait
    /// much longer than a broken server, but is still bounded so this call returns.
    static func retryBudget(for error: Error) -> (attempts: Int, elapsedSeconds: Int) {
        if isOfflineCondition(error) {
            return (
                DownloadRetryPolicy.offlineMaximumAttempts,
                DownloadRetryPolicy.offlineMaximumElapsedSeconds
            )
        }
        return (
            DownloadRetryPolicy.maximumAttempts,
            DownloadRetryPolicy.maximumElapsedSeconds
        )
    }

    /// Maps the failure that exhausted the retry budget onto an actionable error.
    ///
    /// The rendered message reuses the existing translated download strings: a
    /// status-based failure keeps its HTTP status, a stale connection maps onto the
    /// timeout message, and everything else reports an interruption with resumable
    /// progress preserved.
    static func retryExhaustedError(for error: Error, attempts: Int) -> Error {
        let failure: ArtifactDownloadError
        if let retryable = error as? RetryableHTTPError {
            failure = .httpStatus(retryable.statusCode)
        } else if let downloadError = error as? ArtifactDownloadError {
            // `.incompleteDownload` promises the download will keep retrying, which
            // is exactly what just stopped being true.
            failure = downloadError == .incompleteDownload ? .networkInterrupted : downloadError
        } else if let urlError = error as? URLError, urlError.code == .timedOut {
            failure = .timedOut
        } else {
            failure = .networkInterrupted
        }
        return DownloadRetryExhaustedError(attempts: attempts, lastFailure: failure)
    }

    static func retryDelaySeconds(
        for error: Error,
        attempt: Int,
        scheduledDelays: [Int]
    ) -> Int {
        if let retryable = error as? RetryableHTTPError, let retryAfter = retryable.retryAfterSeconds {
            // Clamped at both ends: `Retry-After: 0` must not become a hot loop, and
            // a far-future date must not become a multi-millennium sleep.
            return DownloadRetryPolicy.clampedDelay(retryAfter)
        }
        precondition(!scheduledDelays.isEmpty, "Retry schedule must not be empty")
        return scheduledDelays[min(max(attempt, 0), scheduledDelays.count - 1)]
    }

    static func userFacingError(for error: Error) -> Error {
        if let retryable = error as? RetryableHTTPError {
            return ArtifactDownloadError.httpStatus(retryable.statusCode)
        }
        if let downloadError = error as? ArtifactDownloadError {
            return downloadError
        }
        if FileSystemFailure.isOutOfSpace(error) {
            return ArtifactDownloadError.diskFull
        }
        if FileSystemFailure.isPermissionDenied(error) {
            return ArtifactDownloadError.fileWriteFailed
        }
        guard let urlError = error as? URLError else { return error }

        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .dataNotAllowed,
             .internationalRoamingOff:
            return ArtifactDownloadError.networkInterrupted
        case .timedOut:
            return ArtifactDownloadError.timedOut
        case .cannotWriteToFile:
            return ArtifactDownloadError.diskFull
        case .badServerResponse,
             .cannotParseResponse,
             .zeroByteResource,
             .cannotDecodeRawData,
             .cannotDecodeContentData,
             .badURL,
             .unsupportedURL,
             .redirectToNonExistentLocation:
            return ArtifactDownloadError.invalidResponse
        default:
            return error
        }
    }

    // MARK: - Helpers

    static func httpStatusError(for response: HTTPURLResponse) -> Error {
        let status = response.statusCode
        if status == 429 || (500...599).contains(status) {
            return RetryableHTTPError(statusCode: status, retryAfterSeconds: nil)
        }
        return ArtifactDownloadError.httpStatus(status)
    }

    static func isDiskSpaceExhausted(
        at url: URL,
        remainingBytes: Int64,
        expectedByteCount: Int64
    ) throws -> Bool {
        let reserve = min(diskSpaceReserveBytes, max(expectedByteCount, 1))
        let required = max(remainingBytes, 0) + reserve
        let available = try availableCapacity(at: url)
        return available < required
    }

    static func availableCapacity(at url: URL) throws -> Int64 {
        try DiskCapacity.available(at: BonsaiInstaller.deepestExistingAncestor(of: url))
    }

    static func fileSize(at url: URL) throws -> Int64 {
        try ManagedFileSystem.requiredFileSize(at: url)
    }

}

/// Thread-safe one-shot box used to carry an abort reason out of the progress task.
private final class DownloadAbortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    func record(_ error: Error) {
        lock.withLock {
            if storedError == nil {
                storedError = error
            }
        }
    }

    var error: Error? {
        lock.withLock { storedError }
    }
}
