import Foundation
import Testing
@testable import Launcher27B

struct InstallationCatalogTests {
    @Test
    func catalogPinsOfficialArtifactsAndChecksums() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "BonsaiCatalogTests-\(UUID().uuidString)"
        )
        let config = makeConfig(root: root)
        let artifacts = InstallationCatalog().artifacts(for: config)

        #expect(artifacts.map(\.component) == InstallationComponent.allCases)
        #expect(artifacts.reduce(Int64(0)) { $0 + $1.expectedByteCount } == 7_856_761_610)
        #expect(artifacts.allSatisfy { $0.expectedSHA256.count == 64 })
        #expect(
            artifacts.first(where: { $0.component == .model })?.downloadURL.absoluteString
                .contains(InstallationCatalog.modelRevision) == true
        )
        #expect(
            artifacts.first(where: { $0.component == .adapter })?.downloadURL.absoluteString
                .contains(InstallationCatalog.adapterRevision) == true
        )
    }

    private func makeConfig(root: URL) -> LauncherConfig {
        LauncherConfig(
            serverBinary: root.appending(path: "runtime/mac/llama-server"),
            modelFile: root.appending(path: "models/27B/model.gguf"),
            projectorFile: root.appending(path: "models/27B/mmproj.gguf"),
            ablationAdapterFile: root.appending(path: "modules/orcabonsai/adapter.gguf"),
            webUIConfigFile: root.appending(path: "webui.json"),
            chatURL: URL(string: "http://127.0.0.1:8080/")!,
            contextSize: "32768",
            reasoningBudget: "2048",
            logDirectory: root.appending(path: "logs")
        )
    }
}
