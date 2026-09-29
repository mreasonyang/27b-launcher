import Foundation
import Testing
@testable import Launcher27B

/// Coverage for the stall watchdog's offline branch.
///
/// A unit test may not take a real network path down, so `ArtifactDownloader`
/// exposes a seam: `connectivityWaitOverride` stands in for URLSession's
/// `urlSession(_:taskIsWaitingForConnectivity:)` callback. The watchdog turns that
/// state into `URLError(.notConnectedToInternet)` rather than `URLError(.timedOut)`,
/// and the retry loop answers those two with very different budgets —
/// ``DownloadRetryPolicy/offlineMaximumAttempts`` parked attempts versus the five a
/// wedged-but-reachable server gets. Nothing else about an attempt changes, so the
/// observable consequence of the mapping is exactly that budget. The contrast case
/// (a stalled endpoint that is *not* parked gives up after `maximumAttempts` with
/// `.timedOut`) is `InstallerRobustnessTests.boundsAnAttemptAgainstAStalledEndpoint`.
@Suite(.serialized)
struct DownloadWatchdogSeamTests {
    private actor RetryObservation {
        private(set) var maximumRetryAttempt = 0
        /// Only the in-attempt reporter emits `retryAttempt: 0`; the retry branch
        /// increments first. Seeing it proves the attempt itself was reported as
        /// parked on connectivity, i.e. that the seam reached the watchdog.
        private(set) var sawParkedAttempt = false

        func record(_ update: ArtifactDownloadUpdate) {
            guard case let .waitingForNetwork(retryAttempt, _) = update.state else { return }
            maximumRetryAttempt = max(maximumRetryAttempt, retryAttempt)
            if retryAttempt == 0 {
                sawParkedAttempt = true
            }
        }

        /// Polls until the loop has retried past `target`, or `seconds` elapse.
        ///
        /// A deadline rather than an open-ended wait, so a stalled retry loop cannot hang
        /// the suite.
        func waitForRetryAttempt(exceeding target: Int, seconds: Double = 30) async {
            let deadline = Date().addingTimeInterval(seconds)
            while maximumRetryAttempt <= target, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    @Test
    func parkedOnConnectivityGetsTheOfflineRetryBudgetNotTheWedgedOne() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-watchdog-seam-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The same "accepts the connection and never answers" fixture the wedged-path
        // test uses; only the watchdog's verdict differs.
        let fixture = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/robustness_probe_server.py")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = [fixture.path, "--mode", "stall", "--port", "0", "--log", ""]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        defer { process.terminate() }
        let data = output.fileHandleForReading.availableData
        let port = try #require(
            Int(String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        )

        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:\(port)/model.gguf")!,
            destinationURL: root.appending(path: "model.gguf"),
            expectedByteCount: 8 * 1024 * 1024,
            expectedSHA256: String(repeating: "0", count: 64),
            kind: .file
        )
        let observation = RetryObservation()
        let downloader = ArtifactDownloader(
            retryDelaysSeconds: [0],
            attemptStallTimeoutSeconds: 1,
            connectivityWaitOverride: { true }
        )
        let download = Task {
            try await downloader.download(
                artifact: artifact,
                to: root.appending(path: "model.download"),
                resumeDataURL: root.appending(path: "model.resume"),
                progressDataURL: root.appending(path: "model.progress")
            ) { update in
                await observation.record(update)
            }
        }

        // Stop once the loop has proved it is using the offline budget. With the
        // wedged budget it would already have thrown after `maximumAttempts` retries,
        // so this cannot be reached if `.notConnectedToInternet` is not the verdict.
        await observation.waitForRetryAttempt(exceeding: DownloadRetryPolicy.maximumAttempts)
        download.cancel()
        _ = try? await download.value

        let observedAttempts = await observation.maximumRetryAttempt
        let sawParkedAttempt = await observation.sawParkedAttempt
        #expect(
            observedAttempts > DownloadRetryPolicy.maximumAttempts,
            "a parked attempt must get the offline budget, saw \(observedAttempts) of \(DownloadRetryPolicy.offlineMaximumAttempts)"
        )
        #expect(sawParkedAttempt)
    }
}
