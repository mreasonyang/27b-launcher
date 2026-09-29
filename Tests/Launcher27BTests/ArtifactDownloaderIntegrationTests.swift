import Foundation
import Testing
@testable import Launcher27B

@Suite(.serialized)
struct ArtifactDownloaderIntegrationTests {
    private actor Observation {
        private(set) var sawWaiting = false
        private(set) var sawResuming = false
        private(set) var sawSpeedAndETA = false
        private(set) var minimumResumedBytes: Int64?

        func record(_ update: ArtifactDownloadUpdate) {
            if let speed = update.bytesPerSecond,
               let eta = update.estimatedTimeRemaining,
               speed > 0,
               eta >= 0 {
                sawSpeedAndETA = true
            }
            switch update.state {
            case .waitingForNetwork:
                sawWaiting = true
            case let .downloading(isResuming):
                if isResuming {
                    sawResuming = true
                    minimumResumedBytes = min(
                        minimumResumedBytes ?? update.completedBytes,
                        update.completedBytes
                    )
                }
            }
        }
    }

    private actor PauseGate {
        private var reached = false
        private var continuation: CheckedContinuation<Void, Never>?

        func record(_ update: ArtifactDownloadUpdate) {
            guard update.completedBytes >= 1_048_576, !reached else { return }
            reached = true
            continuation?.resume()
            continuation = nil
        }

        func wait() async {
            if reached { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    /// Releases the fixture server's truncated response once the downloader has
    /// durably persisted the prefix.
    ///
    /// The server dropping mid-body is only deterministic if the client has already
    /// read the prefix: the kernel discards unread bytes when the socket is torn down,
    /// so an un-synchronised drop lets the client observe anywhere from 0 to the full
    /// prefix. Writing the release file from the progress callback guarantees the
    /// bytes are on disk -- and therefore out of the socket buffer -- before the drop.
    private actor DropGate {
        private let threshold: Int64
        private let releaseURL: URL
        private var released = false

        init(threshold: Int64, releaseURL: URL) {
            self.threshold = threshold
            self.releaseURL = releaseURL
        }

        func record(_ update: ArtifactDownloadUpdate) {
            guard !released, update.completedBytes >= threshold else { return }
            released = true
            try? FileManager.default.createDirectory(
                at: releaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data().write(to: releaseURL)
        }
    }

    @Test
    func userPausePersistsResumeDataBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-pause-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = try startServer(mode: "serve")
        defer { server.process.terminate() }
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:\(server.port)/model.gguf")!,
            destinationURL: root.appending(path: "model.gguf"),
            expectedByteCount: 8 * 1024 * 1024,
            expectedSHA256: String(repeating: "0", count: 64),
            kind: .file
        )
        let resumeURL = root.appending(path: "model.resume")
        let progressURL = root.appending(path: "model.progress")
        let gate = PauseGate()
        let downloader = ArtifactDownloader(retryDelaysSeconds: [0])
        let download = Task {
            try await downloader.download(
                artifact: artifact,
                to: artifact.destinationURL,
                resumeDataURL: resumeURL,
                progressDataURL: progressURL
            ) { update in
                await gate.record(update)
            }
        }

        await gate.wait()
        download.cancel()
        do {
            _ = try await download.value
            Issue.record("Expected the paused download to be cancelled")
        } catch {
            #expect(ServiceController.isInstallationCancellation(error))
        }

        let resumeSize = try FileManager.default.attributesOfItem(atPath: resumeURL.path)[.size]
            as? NSNumber
        #expect((resumeSize?.int64Value ?? 0) > 0)

        let observation = Observation()
        _ = try await downloader.download(
            artifact: artifact,
            to: artifact.destinationURL,
            resumeDataURL: resumeURL,
            progressDataURL: progressURL
        ) { update in
            await observation.record(update)
        }
        #expect(await observation.sawResuming)
    }

    @Test
    func automaticallyRetriesAndResumesAfterConnectionDrops() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-resume-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let releaseURL = root.appending(path: "drop.release")
        let server = try startServer(mode: "drop_then_serve", releaseFile: releaseURL)
        defer { server.process.terminate() }
        let artifact = InstallationArtifact(
            component: .model,
            downloadURL: URL(string: "http://127.0.0.1:\(server.port)/model.gguf")!,
            destinationURL: root.appending(path: "model.gguf"),
            expectedByteCount: 8 * 1024 * 1024,
            expectedSHA256: String(repeating: "0", count: 64),
            kind: .file
        )
        let resumeURL = root.appending(path: "model.resume")
        let progressURL = root.appending(path: "model.progress")
        let observation = Observation()
        // Must match DROP_AFTER in interrupted_range_server.py.
        let gate = DropGate(threshold: 1_048_576, releaseURL: releaseURL)
        let downloader = ArtifactDownloader(retryDelaysSeconds: [0, 0, 0])

        let downloadedURL = try await downloader.download(
            artifact: artifact,
            to: artifact.destinationURL,
            resumeDataURL: resumeURL,
            progressDataURL: progressURL
        ) { update in
            await gate.record(update)
            await observation.record(update)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: downloadedURL.path)
        #expect((attributes[.size] as? NSNumber)?.int64Value == artifact.expectedByteCount)
        #expect(await observation.sawWaiting)
        #expect(await observation.sawResuming)
        #expect(await observation.sawSpeedAndETA)
        #expect((await observation.minimumResumedBytes ?? 0) > 0)
        #expect(!FileManager.default.fileExists(atPath: resumeURL.path))
        #expect(!FileManager.default.fileExists(atPath: progressURL.path))
    }

    private func startServer(
        mode: String,
        port: Int = 0,
        releaseFile: URL? = nil
    ) throws -> (process: Process, port: Int) {
        let fixture = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/interrupted_range_server.py")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        var arguments = [fixture.path, "--mode", mode, "--port", String(port)]
        if let releaseFile {
            arguments.append(contentsOf: ["--release-file", releaseFile.path])
        }
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()

        let data = output.fileHandleForReading.availableData
        guard let line = String(data: data, encoding: .utf8),
              let actualPort = Int(line.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            process.terminate()
            throw CocoaError(.fileReadCorruptFile)
        }
        return (process, actualPort)
    }
}
