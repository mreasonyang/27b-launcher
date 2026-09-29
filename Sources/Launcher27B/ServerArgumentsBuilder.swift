import Foundation

struct ServerArgumentsBuilder: Sendable {
    /// `-lv 2` keeps warnings and errors while metrics remain available through
    /// the dedicated metrics endpoint.
    static let logVerbosity = "2"
    /// Cross-origin requests are answered for localhost origins only. Sent in
    /// `allInterfaces` mode; the bundled Web UI is same-origin either way.
    static let corsOrigins = "localhost"

    func makeArguments(
        config: LauncherConfig,
        options: ServerLaunchOptions
    ) -> [String] {
        var arguments = [
            "-m", config.modelFile.path,
            "--host", options.bindMode.hostArgument,
            "--port", "8080",
            "-ngl", "99",
            "-fa", "on",
            "-c", config.contextSize,
            "--temp", "1.0",
            "--top-p", "0.95",
            "--top-k", "20",
            "--jinja",
            "--mmproj", config.projectorFile.path,
            "--image-max-tokens", "1024",
            "--webui-config-file", config.webUIConfigFile.path,
            "--metrics"
        ]

        // Built-in agent tools are off by default in this build (`--help`:
        // "default: disabled", and the running server reports
        // `cors_proxy_enabled = false`), so this only pins the current
        // behaviour against an inherited LLAMA_ARG_AGENT / LLAMA_ARG_TOOLS.
        // It never touches CORS or the chat UI, so it is safe in both modes.
        arguments.append("--no-agent")

        // Keep the dedicated log focused on warnings and errors. Metrics remain
        // available through the metrics endpoint. Log-only, so this is safe in both modes.
        arguments.append(contentsOf: ["-lv", Self.logVerbosity])

        if options.bindMode == .allInterfaces {
            // Reaching the local network: require a key, drop the browser UI
            // and refuse cross-origin callers. Loopback keeps today's argument
            // set untouched so the bundled chat UI keeps working.
            arguments.append(contentsOf: ["--api-key-file", "/dev/stdin"])
            arguments.append(contentsOf: ["--cors-origins", Self.corsOrigins])
            arguments.append("--no-webui")
        }

        if options.ablationEnabled {
            if options.ablationStrength == .exact {
                arguments.append(contentsOf: ["--lora", config.ablationAdapterFile.path])
            } else {
                arguments.append(contentsOf: [
                    "--lora-scaled",
                    "\(config.ablationAdapterFile.path):\(options.ablationStrength.rawValue)"
                ])
            }
        }

        arguments.append(contentsOf: ["--reasoning-budget", config.reasoningBudget])
        return arguments
    }
}
