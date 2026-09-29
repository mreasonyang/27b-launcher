import Foundation

/// Error surfaced when the server answers with a retryable HTTP status.
///
/// Kept separate from `ArtifactDownloadError` so the `Retry-After` hint can travel
/// with the failure while the user-facing error stays the plain `httpStatus` case.
struct RetryableHTTPError: Error, Sendable, Equatable {
    let statusCode: Int
    let retryAfterSeconds: Int?
}

/// Internal signal asking the download loop to discard resume metadata and start over.
///
/// Produced when the server ignores (or rewrites) the requested `Range`, which means
/// appending to the existing partial file would corrupt it.
enum DownloadRecoverySignal: Error, Sendable, Equatable {
    case restartFromZero
}

/// Hard bounds on the automatic retry loop.
///
/// Without these the loop could not terminate: a server that always answers
/// `503 + Retry-After: 0` produced ~900 requests/second forever, and a captive portal
/// answering a short `200` kept failing as `.incompleteDownload` and retrying
/// indefinitely, so the UI sat in "网络中断，等待自动重试" and `download()` never returned.
enum DownloadRetryPolicy {
    /// Floor for a server-supplied `Retry-After`. A hostile/broken `Retry-After: 0`
    /// must not be able to turn the retry loop into a hot request loop.
    static let minimumDelaySeconds = 1
    /// Ceiling for a server-supplied `Retry-After`; far-future dates are clamped
    /// so a server cannot keep a download asleep beyond a useful retry window.
    static let maximumDelaySeconds = 300
    /// Consecutive retryable failures tolerated inside one `download()` call. The
    /// budget is consecutive because nothing resets it: an attempt either returns the
    /// finished file or hands control back to the retry branch.
    static let maximumAttempts = 5
    /// Total time that may be spent sleeping between retries inside one `download()`
    /// call. A second, wall-clock bound so a server handing out the ceiling
    /// `Retry-After` on every attempt cannot keep the loop alive for hours.
    static let maximumElapsedSeconds = 600
    /// Consecutive retryable failures tolerated for the *offline/captive-portal* class
    /// (no network, TLS interception, DNS failure).
    ///
    /// Deliberately far larger than ``maximumAttempts``: those failures are fixed by
    /// the user joining the network or signing in to a portal, so a dropped network
    /// should self-heal rather than give up on the first attempt. It is still a hard
    /// bound, and the bound is a *product* of two numbers: a parked attempt is held for
    /// the per-attempt stall timeout (120 s by default) before it is retried, so this
    /// count caps the wait at roughly 40 minutes — after which `download()` returns and
    /// the UI stops sitting on "waiting for network" forever. The count was halved from
    /// 40 when the per-attempt timeout doubled, so the total wait is unchanged.
    static let offlineMaximumAttempts = 20
    /// Ceiling on the time spent *sleeping between* offline retries. Combined with
    /// ``offlineMaximumAttempts`` and the per-attempt stall timeout this bounds the
    /// total wait; it is not by itself the wall-clock bound.
    static let offlineMaximumElapsedSeconds = 600

    /// Clamps a server-supplied `Retry-After` into `[minimumDelaySeconds, maximumDelaySeconds]`.
    static func clampedDelay(_ seconds: Int) -> Int {
        min(max(seconds, minimumDelaySeconds), maximumDelaySeconds)
    }
}

/// Raised when ``DownloadRetryPolicy`` is exhausted and the download gives up.
///
/// Deliberately a distinct type so a caller can tell "the server failed once" from
/// "we retried for a bounded while and stopped", while its rendering reuses the
/// existing translated download messages (adding new localization keys would mean
/// editing `Resources/*.lproj`, which this change does not own).
struct DownloadRetryExhaustedError: LocalizedError, AppLocalizableError, Equatable {
    /// Number of automatic retries that were spent before giving up.
    let attempts: Int
    /// The failure the last attempt ended with.
    let lastFailure: ArtifactDownloadError

    var errorDescription: String? {
        lastFailure.errorDescription
    }

    @MainActor
    func localizedDescription(using preferences: AppPreferences) -> String {
        lastFailure.localizedDescription(using: preferences)
    }
}

enum ArtifactDownloadError: LocalizedError, AppLocalizableError, Equatable {
    case missingTemporaryFile
    case invalidResponse
    case httpStatus(Int)
    case networkInterrupted
    case timedOut
    case resumeDataPersistenceFailed
    case incompleteDownload
    case diskFull
    case fileWriteFailed
    case unexpectedContentType
    case unexpectedContentLength(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .missingTemporaryFile:
            "下载结束，但没有生成临时文件"
        case .invalidResponse:
            "下载服务器返回了无法识别的响应"
        case let .httpStatus(status):
            "下载服务器返回 HTTP \(status)"
        case .networkInterrupted:
            "网络连接中断，已保存可续传进度；恢复网络后继续下载。"
        case .timedOut:
            "下载等待超时，已保存可续传进度；请检查网络后继续下载。"
        case .resumeDataPersistenceFailed:
            "下载已暂停，但无法保存续传进度；请检查磁盘空间和文件权限。"
        case .incompleteDownload:
            "下载未完成，已保留可续传进度；将继续重试。"
        case .diskFull:
            "磁盘空间不足，下载已暂停；已保留已下载的部分，清理磁盘后可继续。"
        case .fileWriteFailed:
            "无法写入下载文件；请检查磁盘空间和文件夹权限。"
        case .unexpectedContentType:
            "下载服务器返回了网页而不是模型文件，可能被网络登录页面拦截；请连接正常网络后重试。"
        case let .unexpectedContentLength(expected, actual):
            "下载内容大小与预期不符（预期 \(expected.formatted(.byteCount(style: .file)))，"
                + "实际 \(actual.formatted(.byteCount(style: .file)))）；请重试下载。"
        }
    }

    @MainActor
    func localizedDescription(using preferences: AppPreferences) -> String {
        switch self {
        case .missingTemporaryFile:
            preferences.localized("下载结束，但没有生成临时文件")
        case .invalidResponse:
            preferences.localized("下载服务器返回了无法识别的响应")
        case let .httpStatus(status):
            preferences.localizedFormat("下载服务器返回 HTTP %lld", Int64(status))
        case .networkInterrupted:
            preferences.localized("网络连接中断，已保存可续传进度；恢复网络后继续下载。")
        case .timedOut:
            preferences.localized("下载等待超时，已保存可续传进度；请检查网络后继续下载。")
        case .resumeDataPersistenceFailed:
            preferences.localized("下载已暂停，但无法保存续传进度；请检查磁盘空间和文件权限。")
        case .incompleteDownload:
            preferences.localized("下载未完成，已保留可续传进度；将继续重试。")
        case .diskFull:
            preferences.localized("磁盘空间不足，下载已暂停；已保留已下载的部分，清理磁盘后可继续。")
        case .fileWriteFailed:
            preferences.localized("无法写入下载文件；请检查磁盘空间和文件夹权限。")
        case .unexpectedContentType:
            preferences.localized(
                "下载服务器返回了网页而不是模型文件，可能被网络登录页面拦截；请连接正常网络后重试。"
            )
        case let .unexpectedContentLength(expected, actual):
            preferences.localizedFormat(
                "下载内容大小与预期不符（预期 %@，实际 %@）；请重试下载。",
                expected.formatted(.byteCount(style: .file)),
                actual.formatted(.byteCount(style: .file))
            )
        }
    }
}
