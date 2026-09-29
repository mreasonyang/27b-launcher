import Foundation
import Testing
@testable import Launcher27B

struct ServerArgumentsBuilderTests {
    @Test
    func enablesExactServerTokenMetrics() {
        let arguments = ServerArgumentsBuilder().makeArguments(
            config: testConfig(),
            options: ServerLaunchOptions(
                ablationEnabled: false,
                ablationStrength: .exact,
                bindMode: .loopback
            )
        )

        #expect(arguments.contains("--metrics"))
    }

    @Test
    func originalModeDoesNotLoadAdapter() {
        let arguments = ServerArgumentsBuilder().makeArguments(
            config: testConfig(),
            options: ServerLaunchOptions(
                ablationEnabled: false,
                ablationStrength: .exact,
                bindMode: .loopback
            )
        )

        #expect(!arguments.contains("--lora"))
        #expect(!arguments.contains("--lora-scaled"))
    }

    @Test
    func exactProjectionUsesDefaultLoraScale() throws {
        let config = testConfig()
        let arguments = ServerArgumentsBuilder().makeArguments(
            config: config,
            options: ServerLaunchOptions(
                ablationEnabled: true,
                ablationStrength: .exact,
                bindMode: .loopback
            )
        )

        let loraIndex = try #require(arguments.firstIndex(of: "--lora"))
        #expect(arguments[loraIndex + 1] == config.ablationAdapterFile.path)
        #expect(!arguments.contains("--lora-scaled"))
    }

    @Test
    func customProjectionUsesScaledLoraArgument() throws {
        let config = testConfig()
        let arguments = ServerArgumentsBuilder().makeArguments(
            config: config,
            options: ServerLaunchOptions(
                ablationEnabled: true,
                ablationStrength: .moderate,
                bindMode: .loopback
            )
        )

        let loraIndex = try #require(arguments.firstIndex(of: "--lora-scaled"))
        #expect(arguments[loraIndex + 1] == "\(config.ablationAdapterFile.path):0.7")
        #expect(!arguments.contains("--lora"))
    }

    @Test
    func loopbackModeBindsOnlyToThisMac() throws {
        let arguments = ServerArgumentsBuilder().makeArguments(
            config: testConfig(),
            options: ServerLaunchOptions(
                ablationEnabled: false,
                ablationStrength: .exact,
                bindMode: .loopback
            )
        )

        let hostIndex = try #require(arguments.firstIndex(of: "--host"))
        #expect(arguments[hostIndex + 1] == "127.0.0.1")
    }

    @Test
    func allInterfacesModeBindsZeroAddress() throws {
        let arguments = ServerArgumentsBuilder().makeArguments(
            config: testConfig(),
            options: ServerLaunchOptions(
                ablationEnabled: false,
                ablationStrength: .exact,
                bindMode: .allInterfaces
            )
        )

        let hostIndex = try #require(arguments.firstIndex(of: "--host"))
        #expect(arguments[hostIndex + 1] == "0.0.0.0")
    }

    private func testConfig() -> LauncherConfig {
        LauncherConfig(
            serverBinary: URL(fileURLWithPath: "/tmp/runtime/llama-server"),
            modelFile: URL(fileURLWithPath: "/tmp/model.gguf"),
            projectorFile: URL(fileURLWithPath: "/tmp/mmproj.gguf"),
            ablationAdapterFile: URL(fileURLWithPath: "/tmp/adapter.gguf"),
            webUIConfigFile: URL(fileURLWithPath: "/tmp/webui.json"),
            chatURL: URL(string: "http://127.0.0.1:8080/")!,
            contextSize: "32768",
            reasoningBudget: "2048",
            logDirectory: URL(fileURLWithPath: "/tmp/logs")
        )
    }
}
