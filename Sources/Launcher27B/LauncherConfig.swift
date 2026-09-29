import Foundation

struct LauncherConfig: Sendable, Equatable {
    static let supportDirectoryOverrideKey = "LAUNCHER27B_SUPPORT_DIRECTORY"

    let serverBinary: URL
    private let initialModelFile: URL
    private let initialProjectorFile: URL
    let ablationAdapterFile: URL
    let webUIConfigFile: URL
    let chatURL: URL
    let contextSize: String
    let reasoningBudget: String
    let logDirectory: URL

    init(serverBinary: URL, modelFile: URL, projectorFile: URL, ablationAdapterFile: URL,
         webUIConfigFile: URL, chatURL: URL, contextSize: String, reasoningBudget: String, logDirectory: URL) {
        self.serverBinary = serverBinary.standardizedFileURL.resolvingSymlinksInPath()
        self.initialModelFile = modelFile
        self.initialProjectorFile = projectorFile
        self.ablationAdapterFile = ablationAdapterFile
        self.webUIConfigFile = webUIConfigFile
        self.chatURL = chatURL
        self.contextSize = contextSize
        self.reasoningBudget = reasoningBudget
        self.logDirectory = logDirectory
    }

    var modelFile: URL { modelsDirectory.appending(path: "27B/" + initialModelFile.lastPathComponent) }
    var projectorFile: URL { modelsDirectory.appending(path: "27B/" + initialProjectorFile.lastPathComponent) }
    var modelLocationRecord: URL { supportDirectory.appending(path: "model-location.json") }
    private struct ModelLocation: Codable { let path: String; let retainedSource: String? }
    var defaultModelsDirectory: URL { initialModelFile.deletingLastPathComponent().deletingLastPathComponent() }
    var hasCustomModelLocation: Bool { get throws { try ManagedFileSystem.metadata(at: modelLocationRecord) != nil } }
    func configuredModelsDirectory() throws -> URL {
        guard try hasCustomModelLocation else { return defaultModelsDirectory }
        let location = try JSONDecoder().decode(ModelLocation.self, from: Data(contentsOf: modelLocationRecord))
        guard location.path.hasPrefix("/"), location.path != "/" else { throw ModelStorageError.verificationFailed }
        return URL(filePath: location.path, directoryHint: .isDirectory)
    }
    var retainedModelSource: URL? {
        get throws {
            guard try hasCustomModelLocation else { return nil }
            let record = try JSONDecoder().decode(ModelLocation.self, from: Data(contentsOf: modelLocationRecord))
            guard let source = record.retainedSource else { return nil }
            guard source.hasPrefix("/"), source != "/" else { throw ModelStorageError.verificationFailed }
            let url = URL(filePath: source)
            guard try ManagedFileSystem.metadata(at: url) != nil else { return nil }
            return url
        }
    }
    func setModelsDirectory(_ url: URL, retainedSource: URL? = nil) throws {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(ModelLocation(path: canonical.path, retainedSource: retainedSource?.path)).write(to: modelLocationRecord, options: .atomic)
    }

    var supportDirectory: URL {
        initialModelFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    var downloadsDirectory: URL {
        supportDirectory.appending(path: "downloads", directoryHint: .isDirectory)
    }

    func resumeDataURL(for component: InstallationComponent) -> URL {
        downloadsDirectory.appending(path: "\(component.rawValue).resume")
    }

    func progressDataURL(for component: InstallationComponent) -> URL {
        downloadsDirectory.appending(path: "\(component.rawValue).progress")
    }

    var modelsDirectory: URL {
        // Corrupt configuration is unavailable; never silently use another model tree.
        do { return try configuredModelsDirectory() }
        catch { return supportDirectory.appending(path: ".invalid-model-location") }
    }

    var standardOutputURL: URL {
        logDirectory.appending(path: "server.log")
    }

    var standardErrorURL: URL {
        logDirectory.appending(path: "server.error.log")
    }

    static var localInstallation: LauncherConfig {
        makeLocalInstallation()
    }

    /// Environment consulted by ``localInstallation``.
    ///
    /// Release builds deliberately ignore the process environment: the
    /// ``supportDirectoryOverrideKey`` escape hatch lets anything that can call
    /// `launchctl setenv` (or a wrapper script) redirect `serverBinary` at an
    /// arbitrary executable, which the GUI would then launch. Debug builds and
    /// the test suite keep the override so isolated QA installs still work.
    static var processEnvironment: [String: String] {
        #if DEBUG
        ProcessInfo.processInfo.environment
        #else
        [:]
        #endif
    }

    static func makeLocalInstallation(
        environment: [String: String] = LauncherConfig.processEnvironment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LauncherConfig {
        let supportOverride = environment[supportDirectoryOverrideKey]
            .flatMap { path -> URL? in
                guard path.hasPrefix("/"), !path.isEmpty else { return nil }
                return URL(filePath: path, directoryHint: .isDirectory)
            }
        let support = supportOverride ?? homeDirectory.appending(
            path: "Library/Application Support/Bonsai2",
            directoryHint: .isDirectory
        )
        let runtime = support.appending(path: "runtime/mac")
        let modelDirectory = support.appending(path: "models/27B")
        let moduleDirectory = support.appending(path: "modules/orcabonsai")
        let bundledWebUIConfig = Bundle.main.bundleURL.appending(path: "Contents/Resources/webui-config.json")

        return LauncherConfig(
            serverBinary: runtime.appending(path: "llama-server"),
            modelFile: modelDirectory.appending(path: "Ternary-Bonsai-2-27B-PQ2_0.gguf"),
            projectorFile: modelDirectory.appending(path: "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"),
            ablationAdapterFile: moduleDirectory.appending(path: "bonsai-abliterate-lora.gguf"),
            webUIConfigFile: bundledWebUIConfig,
            chatURL: URL(string: "http://127.0.0.1:8080/")!,
            contextSize: "32768",
            reasoningBudget: "2048",
            logDirectory: supportOverride?.appending(path: "logs")
                ?? homeDirectory.appending(path: "Library/Logs/Bonsai2")
        )
    }
}
