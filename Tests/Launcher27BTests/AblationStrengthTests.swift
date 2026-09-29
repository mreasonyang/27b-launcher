import Foundation
import Testing
@testable import Launcher27B

struct AblationStrengthTests {
    @Test
    func optionsUsePlainLanguageDescriptions() {
        #expect(AblationStrength.partial.title == "0.5× · 温和")
        #expect(AblationStrength.moderate.title == "0.7× · 平衡")
        #expect(AblationStrength.strong.title == "0.9× · 强力")
        #expect(AblationStrength.exact.title == "1.0× · 完整效果")
        #expect(AblationStrength.aggressive.title == "2.0× · 默认")

        for strength in AblationStrength.allCases {
            #expect(!strength.explanation.isEmpty)
        }
    }

    @Test @MainActor
    func newInstallationDefaultsToEnabledDoubleStrengthAndPreservesSavedChoices() throws {
        for saved in [nil] + AblationStrength.allCases.map(Optional.some) {
            let name = "27b-strength-default-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            if let saved {
                defaults.set(saved.rawValue, forKey: "orcabonsaiAblationStrength")
                defaults.set(false, forKey: "orcabonsaiAblationEnabled")
            }
            let root = FileManager.default.temporaryDirectory.appending(path: name)
            let config = LauncherConfig.makeLocalInstallation(
                environment: [LauncherConfig.supportDirectoryOverrideKey: root.path], homeDirectory: root)
            let controller = ServiceController(config: config, requiresInstanceLock: false,
                preferences: AppPreferences(defaults: defaults), processManager: StubServerProcessManager(),
                defaults: defaults, healthProbe: { _ in false }, loginItemStatus: { .notRegistered })
            #expect(controller.ablationStrength == (saved ?? .aggressive))
            #expect(controller.ablationEnabled == (saved == nil))
            if let saved { #expect(defaults.string(forKey: "orcabonsaiAblationStrength") == saved.rawValue) }
            else {
                let args = ServerArgumentsBuilder().makeArguments(config: config, options: ServerLaunchOptions(
                    ablationEnabled: controller.ablationEnabled, ablationStrength: controller.ablationStrength, bindMode: .loopback))
                let index = try #require(args.firstIndex(of: "--lora-scaled"))
                #expect(args[index + 1] == "\(config.ablationAdapterFile.path):2.0")
                #expect(!args.contains("--lora"))
            }
        }
    }

}
