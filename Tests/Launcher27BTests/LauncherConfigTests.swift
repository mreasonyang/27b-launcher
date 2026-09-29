import Foundation
import Testing
@testable import Launcher27B

struct LauncherConfigTests {
    @Test
    func defaultInstallationUsesBonsaiSupportDirectory() {
        let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
        let config = LauncherConfig.makeLocalInstallation(
            environment: [:],
            homeDirectory: home
        )

        #expect(
            config.modelFile.path
                == "/Users/tester/Library/Application Support/Bonsai2/models/27B/Ternary-Bonsai-2-27B-PQ2_0.gguf"
        )
        #expect(config.logDirectory.path == "/Users/tester/Library/Logs/Bonsai2")
    }

    @Test
    func absoluteSupportDirectoryOverrideIsIsolated() {
        let config = LauncherConfig.makeLocalInstallation(
            environment: [LauncherConfig.supportDirectoryOverrideKey: "/tmp/launcher-qa"],
            homeDirectory: URL(filePath: "/Users/tester", directoryHint: .isDirectory)
        )

        #expect(config.serverBinary.path == "/tmp/launcher-qa/runtime/mac/llama-server")
        #expect(config.modelFile.path == "/tmp/launcher-qa/models/27B/Ternary-Bonsai-2-27B-PQ2_0.gguf")
        #expect(config.logDirectory.path == "/tmp/launcher-qa/logs")
    }

    @Test
    func relativeSupportDirectoryOverrideIsIgnored() {
        let config = LauncherConfig.makeLocalInstallation(
            environment: [LauncherConfig.supportDirectoryOverrideKey: "relative/path"],
            homeDirectory: URL(filePath: "/Users/tester", directoryHint: .isDirectory)
        )

        #expect(config.serverBinary.path.hasPrefix("/Users/tester/Library/Application Support/Bonsai2"))
    }
}
