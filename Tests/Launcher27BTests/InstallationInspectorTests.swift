import Foundation
import Testing
@testable import Launcher27B

struct InstallationInspectorTests {
    @Test
    func reportsOnlyIncompleteArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "BonsaiInspectorTests-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let config = makeConfig(root: root)
        let artifacts = InstallationCatalog().artifacts(for: config)
        let inspector = InstallationInspector()

        #expect(try inspector.missingArtifacts(from: artifacts, config: config).count == 4)

        for artifact in artifacts {
            try installPlaceholder(for: artifact)
        }

        #expect(try inspector.missingArtifacts(from: artifacts, config: config).isEmpty)

        let handle = try FileHandle(forWritingTo: config.projectorFile)
        try handle.truncate(atOffset: 1)
        try handle.close()

        #expect(
            try inspector.missingArtifacts(from: artifacts, config: config).map(\.component) == [
                .projector
            ]
        )
    }

    private func installPlaceholder(for artifact: InstallationArtifact) throws {
        let fileManager = FileManager.default

        switch artifact.kind {
        case .file:
            try fileManager.createDirectory(
                at: artifact.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            #expect(fileManager.createFile(atPath: artifact.destinationURL.path, contents: nil))
            let handle = try FileHandle(forWritingTo: artifact.destinationURL)
            try handle.truncate(atOffset: UInt64(artifact.expectedByteCount))
            try handle.close()

        case let .runtimeArchive(releaseMarker):
            try fileManager.createDirectory(
                at: artifact.destinationURL,
                withIntermediateDirectories: true
            )
            let serverURL = artifact.destinationURL.appending(path: "llama-server")
            let libraryURL = artifact.destinationURL.appending(path: "libllama-server-impl.dylib")
            #expect(fileManager.createFile(atPath: serverURL.path, contents: Data()))
            #expect(fileManager.createFile(atPath: libraryURL.path, contents: Data()))
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: serverURL.path
            )
            try "\(releaseMarker)\n".write(
                to: artifact.destinationURL.appending(path: ".llama_release"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func makeConfig(root: URL) -> LauncherConfig {
        LauncherConfig(
            serverBinary: root.appending(path: "runtime/mac/llama-server"),
            modelFile: root.appending(path: "models/27B/Ternary-Bonsai-2-27B-PQ2_0.gguf"),
            projectorFile: root.appending(path: "models/27B/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"),
            ablationAdapterFile: root.appending(path: "modules/orcabonsai/bonsai-abliterate-lora.gguf"),
            webUIConfigFile: root.appending(path: "webui.json"),
            chatURL: URL(string: "http://127.0.0.1:8080/")!,
            contextSize: "32768",
            reasoningBudget: "2048",
            logDirectory: root.appending(path: "logs")
        )
    }
}
