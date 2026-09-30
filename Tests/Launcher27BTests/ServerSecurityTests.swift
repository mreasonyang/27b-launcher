import Darwin
import Foundation
import Testing
@testable import Launcher27B

@Suite
struct ServerSecurityTests {
    // MARK: - API key store

    @Test
    func apiKeyStoreGeneratesOneStableURLSafeKey() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MemoryAPIKeyStore().store

        #expect(try store.existingKey() == nil)

        let key = try store.loadOrCreateKey()
        #expect(key.count == 43)
        #expect(!key.contains("+"))
        #expect(!key.contains("/"))
        #expect(!key.contains("="))
        #expect(key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })

        // Stable across launches: a second read returns the persisted value.
        #expect(try store.loadOrCreateKey() == key)
        #expect(try store.existingKey() == key)
    }

    @Test
    func keychainFailureDoesNotCreatePlaintextCredentials() throws {
        let store = ApiKeyStore(read: { throw ApiKeyStoreError.keychainFailure(status: -1) }, write: { _ in Issue.record("must not write after a failed read") })
        #expect(throws: ApiKeyStoreError.self) { try store.loadOrCreateKey() }
    }

    @Test
    func apiKeyRotationReplacesTheStoredKey() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MemoryAPIKeyStore().store
        let original = try store.loadOrCreateKey()
        let rotated = try store.rotateKey()

        #expect(rotated != original)
        #expect(try store.loadOrCreateKey() == rotated)
    }

    @Test
    func launchedLANServerReceivesKeyThroughPipeAndKeepsBirthBoundOptions() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "runtime/mac")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appending(path: "llama-server")
        let source = root.appending(path: "pipe-runtime.c")
        try """
        #include <stdio.h>
        #include <unistd.h>
        int main(void) {
            char key[128];
            if (!fgets(key, sizeof(key), stdin)) return 2;
            FILE *f = fopen("received-key", "w");
            if (!f) return 3;
            for (char *p=key; *p; p++) if (*p=='\\n') { *p=0; break; }
            fputs(key, f); fclose(f); sleep(30); return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(filePath: "/usr/bin/cc")
        compiler.arguments = [source.path, "-o", binary.path]
        try compiler.run(); compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)

        try makeRuntimeSupportFiles(inside: root)
        let name = "27b-pipe-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MemoryAPIKeyStore().store
        let key = try store.loadOrCreateKey()
        let config = testConfig(serverBinary: binary, supportDirectory: root)
        let manager = ServerProcessManager(config: config, defaults: ServerDefaults(defaults), apiKeyStore: store)
        try await manager.start(options: options(bindMode: .allInterfaces))
        let received = binary.deletingLastPathComponent().appending(path: "received-key")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: received.path) { try await Task.sleep(for: .milliseconds(10)) }
        if !FileManager.default.fileExists(atPath: received.path) {
            Issue.record(Comment(rawValue: (try String(contentsOf: config.standardErrorURL, encoding: .utf8)).replacingOccurrences(of: key, with: "[redacted]")))
        }
        #expect(try String(contentsOf: received, encoding: .utf8) == key)
        #expect(await manager.runningLaunchOptions()?.bindMode == .allInterfaces)
        defaults.set("stale-birth", forKey: "serverProcessIdentity")
        #expect(await manager.runningLaunchOptions() == nil)
        // Stop the test-owned native child after deliberately invalidating its record.
        let pid = pid_t(defaults.integer(forKey: "bonsaiServerPID"))
        if pid > 0 { Darwin.kill(pid, SIGTERM) }
        let log = try String(contentsOf: config.standardErrorURL, encoding: .utf8)
        #expect(!log.contains(key))
    }

    @Test
    func startRefusesToPretendAnOrphanUsedRequestedOptions() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = try makeFakeServerBinary(inside: root)
        let child = Process(); child.executableURL = binary; child.arguments = ["30"]
        try child.run(); defer { if child.isRunning { child.terminate() } }
        let name = "27b-orphan-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = ServerProcessManager(config: testConfig(serverBinary: binary, supportDirectory: root), defaults: ServerDefaults(defaults), apiKeyStore: MemoryAPIKeyStore().store)
        await #expect(throws: ServerProcessError.portStillResponding) { try await manager.start(options: options(bindMode: .allInterfaces)) }
        #expect(await manager.runningLaunchOptions() == nil)
        #expect(defaults.dictionary(forKey: "serverLaunchRecord") == nil)
    }

    // MARK: - Server arguments

    @Test
    func lanCredentialsUseAnInheritedPipeAndNeverArguments() {
        let lan = ServerArgumentsBuilder().makeArguments(config: testConfig(), options: options(bindMode: .allInterfaces))
        #expect(lan.contains("--api-key-file"))
        #expect(lan.contains("/dev/stdin"))
        #expect(!lan.contains("--api-key"))
        let local = ServerArgumentsBuilder().makeArguments(config: testConfig(), options: options(bindMode: .loopback))
        #expect(!local.contains("--api-key-file"))
    }

    @Test
    func loopbackKeepsTodaysArgumentSetForTheBundledChatUI() throws {
        let loopback = ServerArgumentsBuilder().makeArguments(
            config: testConfig(),
            options: options(bindMode: .loopback)
        )

        // Invariant protecting the built-in chat UI: loopback never gains the
        // LAN hardening flags.
        #expect(!loopback.contains("--api-key"))
        #expect(!loopback.contains("--no-webui"))
        #expect(!loopback.contains("--cors-origins"))
        #expect(!loopback.contains("--ui-mcp-proxy"))

        // Present today and still present.
        #expect(loopback.contains("--webui-config-file"))
        #expect(loopback.contains("--jinja"))
        #expect(loopback.contains("--metrics"))

        // Safe in both modes: log verbosity and a pin on already-disabled tools.
        #expect(loopback.contains("--no-agent"))
        let verbosityIndex = try #require(loopback.firstIndex(of: "-lv"))
        #expect(loopback[verbosityIndex + 1] == "2")
    }

    @Test
    func allInterfaceBindingDisablesTheWebUIAndAgentTools() throws {
        let config = testConfig()

        let lan = ServerArgumentsBuilder().makeArguments(
            config: config,
            options: options(bindMode: .allInterfaces)
        )
        #expect(lan.contains("--no-webui"))
        #expect(lan.contains("--no-agent"))

        let loopback = ServerArgumentsBuilder().makeArguments(
            config: config,
            options: options(bindMode: .loopback)
        )
        #expect(!loopback.contains("--no-webui"))
        #expect(!loopback.contains("--ui"))
        #expect(loopback.contains("--no-agent"))
    }

    @Test
    func crossOriginRequestsAreRestrictedOnlyInLANMode() throws {
        let config = testConfig()

        let lan = ServerArgumentsBuilder().makeArguments(
            config: config,
            options: options(bindMode: .allInterfaces)
        )
        let corsIndex = try #require(lan.firstIndex(of: "--cors-origins"))
        #expect(lan[corsIndex + 1] == "localhost")
        #expect(lan[corsIndex + 1] == ServerArgumentsBuilder.corsOrigins)

        let loopback = ServerArgumentsBuilder().makeArguments(
            config: config,
            options: options(bindMode: .loopback)
        )
        #expect(!loopback.contains("--cors-origins"))

        let verbosityIndex = try #require(loopback.firstIndex(of: "-lv"))
        #expect(loopback[verbosityIndex + 1] == ServerArgumentsBuilder.logVerbosity)
        #expect(loopback[verbosityIndex + 1] == "2")
    }

    // MARK: - Child environment

    @Test
    func childEnvironmentKeepsOnlyTheAllowlist() {
        let source = [
            "PATH": "/usr/local/bin:/usr/bin",
            "HOME": "/Users/tester",
            "TMPDIR": "/var/folders/xx/T/",
            "LANG": "zh_CN.UTF-8",
            "LC_ALL": "zh_CN.UTF-8",
            "LC_CTYPE": "UTF-8",
            "AWS_SECRET_ACCESS_KEY": "secret",
            "AWS_ACCESS_KEY_ID": "id",
            "HF_TOKEN": "hf_token",
            "HTTPS_PROXY": "http://user:pass@proxy",
            "LLAMA_API_KEY": "leaked",
            "LLAMA_ARG_TOOLS": "all",
            "LLAMA_ARG_HOST": "0.0.0.0",
            "EDITOR": "vim"
        ]

        let environment = ServerProcessManager.childEnvironment(from: source)

        #expect(environment["PATH"] == "/usr/local/bin:/usr/bin")
        #expect(environment["HOME"] == "/Users/tester")
        #expect(environment["TMPDIR"] == "/var/folders/xx/T/")
        #expect(environment["LANG"] == "zh_CN.UTF-8")
        #expect(environment["LC_ALL"] == "zh_CN.UTF-8")
        #expect(environment["LC_CTYPE"] == "UTF-8")

        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(environment["AWS_ACCESS_KEY_ID"] == nil)
        #expect(environment["HF_TOKEN"] == nil)
        #expect(environment["HTTPS_PROXY"] == nil)
        #expect(environment["LLAMA_API_KEY"] == nil)
        #expect(environment["LLAMA_ARG_TOOLS"] == nil)
        #expect(environment["LLAMA_ARG_HOST"] == nil)
        #expect(environment["EDITOR"] == nil)
    }

    @Test
    func childEnvironmentAlwaysProvidesPathAndHome() {
        let environment = ServerProcessManager.childEnvironment(from: [:])

        #expect(environment["PATH"] != nil)
        #expect(environment["HOME"] == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // MARK: - Metrics parser hardening

    @Test
    func parserBoundsHugeCountersInsteadOfTrapping() throws {
        let payload = """
        llamacpp:prompt_tokens_total 1e300
        llamacpp:tokens_predicted_total 9223372036854775808
        llamacpp:prompt_tokens_cached_total -12
        """

        #expect(throws: LlamaMetricsError.invalidResponse) { try LlamaMetricsParser().parse(payload) }
    }

    @Test
    func parserStillAcceptsLargeButRepresentableCounters() throws {
        let payload = """
        llamacpp:prompt_tokens_total 9007199254740992
        llamacpp:tokens_predicted_total 1
        llamacpp:prompt_tokens_cached_total 0
        llamacpp:prompt_tokens_seconds 0
        llamacpp:predicted_tokens_seconds 0
        llamacpp:requests_processing 0
        llamacpp:requests_deferred 0
        llamacpp:n_tokens_max 0
        """

        let usage = try LlamaMetricsParser().parse(payload)

        #expect(usage.processedPromptTokens == 9_007_199_254_740_992)
        #expect(usage.generatedTokens == 1)
    }

    @Test
    func parserDropsNonFiniteRates() throws {
        let payload = """
        llamacpp:prompt_tokens_total 10
        llamacpp:tokens_predicted_total 20
        llamacpp:prompt_tokens_seconds nan
        llamacpp:predicted_tokens_seconds inf
        """

        #expect(throws: LlamaMetricsError.invalidResponse) { try LlamaMetricsParser().parse(payload) }
    }

    // MARK: - Log rotation

    @Test
    func logRotationCapsSizeAndKeepsGenerations() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appending(path: "server.error.log")
        let rotation = ServerLogRotation(maximumBytes: 256, generations: 2)

        for session in 1...5 {
            let handle = try rotation.openLog(
                at: url,
                header: "===== session \(session) =====\n"
            )
            try handle.write(contentsOf: Data(repeating: 0x41, count: 200))
            try handle.close()
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try #require(attributes[.size] as? NSNumber)
        #expect(size.intValue < 512)

        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)

        #expect(FileManager.default.fileExists(atPath: ServerLogRotation
            .rotatedURL(for: url, generation: 1).path))
        #expect(FileManager.default.fileExists(atPath: ServerLogRotation
            .rotatedURL(for: url, generation: 2).path))
        // Only `generations` rotated files are kept.
        #expect(!FileManager.default.fileExists(atPath: ServerLogRotation
            .rotatedURL(for: url, generation: 3).path))

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("===== session 5 ====="))
    }

    @Test
    func logRotationRepairsWorldReadableLogFiles() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appending(path: "server.log")
        try Data("legacy\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )

        let handle = try ServerLogRotation().openLog(at: url, header: "===== session =====\n")
        try handle.close()

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
    }

    /// The cap must be enforced during a live session, because one
    /// long session could grow without bound: a `-lv 2` runtime still logs a line
    /// for every cancelled request. The live file is trimmed *in place* because
    /// the running server appends through the descriptor it inherited from
    /// `openLog` — renaming the file would send every new line into the rotated
    /// generation and leave the file the user opens empty.
    @Test
    func enforceCapTrimsALiveLogWithoutLosingTheTailOrThePermissions() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appending(path: "server.error.log")
        let rotation = ServerLogRotation(maximumBytes: 256, generations: 2)
        let handle = try rotation.openLog(at: url, header: "===== session =====\n")
        defer { try? handle.close() }

        for _ in 0..<40 {
            try handle.write(contentsOf: Data(repeating: 0x42, count: 200))
        }
        #expect(try size(of: url) > 256)
        #expect(!FileManager.default.fileExists(atPath: ServerLogRotation
            .rotatedURL(for: url, generation: 1).path))

        try rotation.enforceCap(at: url, handle: handle)

        // The live file is trimmed …
        #expect(try size(of: url) < 256)
        // … the newest bytes are still available for diagnosis …
        let rotated = ServerLogRotation.rotatedURL(for: url, generation: 1)
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        #expect(try size(of: rotated) == 256)
        // … and both files keep the 0600 repair.
        #expect(try permissions(of: url) == 0o600)
        #expect(try permissions(of: rotated) == 0o600)

        // The session keeps writing into the live file, not into the generation.
        try handle.write(contentsOf: Data("after rotation\n".utf8))
        #expect(try String(contentsOf: url, encoding: .utf8) == "after rotation\n")
    }

    /// End-to-end coverage: a real session that never reopens
    /// its log must still be capped.
    @Test
    func logRotationFiresDuringASingleLongSession() async throws {
        let hostedCI = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = root.appending(path: "payload.txt")
        try Data(repeating: 0x41, count: 60_000).write(to: payload)
        let binary = try makeScriptRuntime(inside: root, body: """
        #!/bin/sh
        cat "\(payload.path)" >&2
        sleep \(hostedCI ? 30 : 10)
        """)
        try makeRuntimeSupportFiles(inside: root)

        let config = testConfig(serverBinary: binary, supportDirectory: root)
        let suiteName = "Launcher27B-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ServerProcessManager(
            config: config,
            defaults: ServerDefaults(defaults),
            apiKeyStore: MemoryAPIKeyStore().store,
            logRotation: ServerLogRotation(maximumBytes: 512, generations: 2)
        )
        try await manager.start(options: options(bindMode: .loopback))

        // ~60 KB are written to stderr by this single session.
        let rotated = ServerLogRotation.rotatedURL(
            for: config.standardErrorURL,
            generation: 1
        )
        let deadline = ContinuousClock().now.advanced(by: .seconds(hostedCI ? 20 : 6))
        while !FileManager.default.fileExists(atPath: rotated.path),
              ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        try? await manager.stop()

        #expect(FileManager.default.fileExists(atPath: rotated.path))
        #expect(try size(of: rotated) > 0)
        #expect(try size(of: config.standardErrorURL) < 60_000)
        // The live file was truncated and rewound on the shared descriptor, so
        // appends land at offset 0 instead of leaving a sparse hole.
        #expect(try !Data(contentsOf: config.standardErrorURL).contains(0x00))
    }

    /// The live log is opened `O_APPEND` on purpose: the running server writes
    /// through a descriptor inherited from the launcher, so the two share a file
    /// offset. Without `O_APPEND`, a write after a rotation that left the offset
    /// high lands at that stale offset and leaves a NUL hole.
    @Test
    func theLiveLogIsOpenedForAppendSoAStaleOffsetCannotHoleIt() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appending(path: "server.error.log")
        let rotation = ServerLogRotation(maximumBytes: 4_096, generations: 2)
        let handle = try rotation.openLog(at: url, header: "header\n")
        defer { try? handle.close() }

        try handle.write(contentsOf: Data("first\n".utf8))

        // Simulate the shared offset a rotation can leave behind…
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("second\n".utf8))

        // …the append must still land at the end, not overwrite the header.
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == "header\nfirst\nsecond\n")
    }

    /// The bytes the cap preserves are the whole point of the feature. If they
    /// cannot be copied out — an unreadable live file here, a full disk or a
    /// read-only directory in the field — the live file must be left alone rather
    /// than truncated, or the newest bytes are lost with nothing saved.
    @Test
    func enforceCapNeverTruncatesWhenTheNewestBytesCannotBePreserved() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appending(path: "server.error.log")
        let rotation = ServerLogRotation(maximumBytes: 256, generations: 2)
        let handle = try rotation.openLog(at: url, header: "===== session =====\n")
        defer { try? handle.close() }

        for _ in 0..<40 {
            try handle.write(contentsOf: Data(repeating: 0x42, count: 200))
        }
        let sizeBefore = try size(of: url)
        #expect(sizeBefore > 256)

        // The live file cannot be read, so the newest bytes cannot be saved.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: url.path
        )
        #expect(throws: (any Error).self) { try rotation.enforceCap(at: url, handle: handle) }

        #expect(try size(of: url) == sizeBefore)
        #expect(!FileManager.default.fileExists(atPath: ServerLogRotation
            .rotatedURL(for: url, generation: 1).path))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Same fail-safe, reached through a failed *copy* instead of a failed read:
    /// the directory is read-only, so generation 1 cannot be created.
    @Test
    func enforceCapNeverTruncatesWhenTheCopyCannotBeWritten() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = root.appending(path: "logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "server.error.log")
        let rotation = ServerLogRotation(maximumBytes: 256, generations: 2)
        let handle = try rotation.openLog(at: url, header: "===== session =====\n")
        defer { try? handle.close() }

        for _ in 0..<40 {
            try handle.write(contentsOf: Data(repeating: 0x42, count: 200))
        }
        let sizeBefore = try size(of: url)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }

        #expect(throws: (any Error).self) { try rotation.enforceCap(at: url, handle: handle) }

        #expect(try size(of: url) == sizeBefore)
    }

    /// The fail-safe claim was too strong: `shiftGenerations(for:)` ran *before*
    /// the preserved copy was written, so a copy that failed still rotated the
    /// older generations away, and nothing `fsync`ed generation 1 before the
    /// live log was truncated. The newest bytes are now staged and made durable
    /// first, and history is shifted only once that copy exists.
    @Test
    func aFailedCopyLeavesTheOlderGenerationsAlone() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appending(path: "server.error.log")
        let rotation = ServerLogRotation(maximumBytes: 256, generations: 2)
        let handle = try rotation.openLog(at: url, header: "===== session =====\n")
        defer { try? handle.close() }

        for _ in 0..<40 {
            try handle.write(contentsOf: Data(repeating: 0x42, count: 200))
        }
        let sizeBefore = try size(of: url)

        let generation1 = ServerLogRotation.rotatedURL(for: url, generation: 1)
        let generation2 = ServerLogRotation.rotatedURL(for: url, generation: 2)
        try Data("OLD1".utf8).write(to: generation1)
        try Data("OLD2".utf8).write(to: generation2)

        // A directory occupying the staging path makes the preservation copy
        // impossible — the field equivalent of a full disk. The staging path is a
        // sibling named `…<ext>.preserving` (`ServerLogRotation.preservingURL`).
        try FileManager.default.createDirectory(
            at: url.appendingPathExtension("preserving"),
            withIntermediateDirectories: true
        )

        #expect(throws: (any Error).self) { try rotation.enforceCap(at: url, handle: handle) }

        // Neither the live file nor any generation was touched by a copy that
        // never happened.
        #expect(try size(of: url) == sizeBefore)
        #expect(try String(contentsOf: generation1, encoding: .utf8) == "OLD1")
        #expect(try String(contentsOf: generation2, encoding: .utf8) == "OLD2")
    }

    @Test
    func failedTruncationIsReportedAndCanBeRetriedAfterRepair() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "server.error.log")
        let rotation = ServerLogRotation(maximumBytes: 256, generations: 2)
        let writer = try rotation.openLog(at: url, header: "header\n")
        defer { try? writer.close() }
        try writer.write(contentsOf: Data(repeating: 0x42, count: 1024))
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        #expect(throws: (any Error).self) { try rotation.enforceCap(at: url, handle: reader) }
        #expect(try size(of: url) > 1024)
        try rotation.enforceCap(at: url, handle: writer)
        #expect(try size(of: url) == 0)
        #expect(try size(of: ServerLogRotation.rotatedURL(for: url, generation: 1)) == 256)
    }

    @Test
    func backgroundLogFailureReachesTheControllerProtocol() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "runtime/mac")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appending(path: "llama-server")
        let source = root.appending(path: "log-runtime.c")
        try "#include <unistd.h>\nint main(void) { sleep(10); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(filePath: "/usr/bin/cc")
        compiler.arguments = [source.path, "-o", binary.path]
        try compiler.run(); compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        try makeRuntimeSupportFiles(inside: root)
        let config = testConfig(serverBinary: binary, supportDirectory: root)
        let name = "27b-log-error-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = ServerProcessManager(config: config, defaults: ServerDefaults(defaults),
            apiKeyStore: MemoryAPIKeyStore().store, logRotation: ServerLogRotation(maximumBytes: 32, generations: 2))
        try await manager.start(options: options(bindMode: .loopback))
        try FileManager.default.createDirectory(at: ServerLogRotation.preservingURL(for: config.standardOutputURL), withIntermediateDirectories: true)
        let protocolValue: any ServerProcessControlling = manager
        let deadline = ContinuousClock().now.advanced(by: .seconds(4))
        while await protocolValue.logMaintenanceFailure() == nil, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let failure = await protocolValue.logMaintenanceFailure()
        try await manager.stop()
        #expect(failure != nil)
        #expect(try size(of: config.standardOutputURL) > 32)
    }

    // MARK: - Single instance lock

    @Test
    func singleInstanceLockRejectsASecondOwner() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = SingleInstanceLock.defaultURL(supportDirectory: root)
        let first = SingleInstanceLock(url: url)
        let second = SingleInstanceLock(url: url)

        #expect(try first.acquire() == .acquired)
        guard case let .alreadyRunning(ownerPID) = try second.acquire() else {
            Issue.record("second launcher acquired the lock while the first holds it")
            return
        }
        #expect(ownerPID == getpid())

        first.release()
        #expect(try second.acquire() == .acquired)
        second.release()
    }

    /// `flock` protects an inode, not a path: deleting the lock file while it is
    /// held lets a new instance create a fresh inode and become primary while the
    /// original owner still believes it is alone. The owner must be able to
    /// notice, so the takeover can be re-decided instead of silently voided.
    @Test
    func deletingTheLockFileWhileHeldIsDetected() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = SingleInstanceLock.defaultURL(supportDirectory: root)
        let lock = SingleInstanceLock(url: url)
        #expect(try lock.acquire() == .acquired)
        #expect(lock.pathStillRefersToHeldFile)

        try FileManager.default.removeItem(at: url)

        #expect(!lock.pathStillRefersToHeldFile)
        lock.release()
    }

    /// The load-bearing case the deletion test alone does not reach: the path is
    /// *recreated* by an intruder, so a simple `attributesOfItem` existence check
    /// still succeeds. Only the inode/device comparison against the held
    /// descriptor can tell that the file at the path is no longer the one this
    /// lock owns — which is exactly the state in which a second instance can take
    /// `flock` and become primary without the first one noticing.
    @Test
    func aReplacedLockFileIsDetectedEvenThoughThePathStillExists() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = SingleInstanceLock.defaultURL(supportDirectory: root)
        let lock = SingleInstanceLock(url: url)
        #expect(try lock.acquire() == .acquired)
        #expect(lock.pathStillRefersToHeldFile)

        // A cleanup tool removes the file, then an "intruder" launcher creates a
        // new one at the same path and locks its own (different) inode.
        try FileManager.default.removeItem(at: url)
        let intruder = SingleInstanceLock(url: url)
        #expect(try intruder.acquire() == .acquired)

        // The path exists again, but it is not the inode this lock holds.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!lock.pathStillRefersToHeldFile)

        // …and the lock reports that a *different* descriptor owns it.
        let third = SingleInstanceLock(url: url)
        guard case .alreadyRunning = try third.acquire() else {
            Issue.record("the replaced lock file was not owned by the intruder")
            return
        }

        intruder.release()
        lock.release()
    }

    @Test
    func singleInstanceLockIsReentrantForTheOwner() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let lock = SingleInstanceLock(url: SingleInstanceLock.defaultURL(supportDirectory: root))
        #expect(try lock.acquire() == .acquired)
        #expect(try lock.acquire() == .acquired)
        #expect(lock.isHeld)
        lock.release()
        #expect(!lock.isHeld)
    }

    // MARK: - Process discovery

    @Test
    func discoveryRequiresTheExpectedExecutableNameInsideTheSupportDirectory() {
        let support = URL(filePath: "/tmp/support", directoryHint: .isDirectory)
        let expected = support.appending(path: "runtime/mac/llama-server")

        #expect(!ServerProcessDiscovery.matches(
            executablePath: "/tmp/support/runtime/mac/llama-server",
            expectedExecutable: expected,
            supportDirectory: support
        ))
        // Reinstalled at a different sub-path inside our own support directory.
        #expect(!ServerProcessDiscovery.matches(
            executablePath: "/tmp/support/runtime/mac-2/llama-server",
            expectedExecutable: expected,
            supportDirectory: support
        ))
        // Same file name outside the support directory is never ours.
        #expect(!ServerProcessDiscovery.matches(
            executablePath: "/opt/other/llama-server",
            expectedExecutable: expected,
            supportDirectory: support
        ))
        // Different binary inside the support directory is not ours either.
        #expect(!ServerProcessDiscovery.matches(
            executablePath: "/tmp/support/runtime/mac/other-server",
            expectedExecutable: expected,
            supportDirectory: support
        ))
    }

    @Test
    func discoversAndStopsAnUnownedServerProcess() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = try makeFakeServerBinary(inside: root)
        let config = testConfig(serverBinary: binary, supportDirectory: root)
        let suiteName = "Launcher27B-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let child = Process()
        child.executableURL = binary
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
        }

        let manager = ServerProcessManager(
            config: config,
            defaults: ServerDefaults(defaults),
            apiKeyStore: MemoryAPIKeyStore().store
        )

        // No PID record: the launcher must not claim ownership...
        let initiallyRunning = await manager.isRunning()
        #expect(initiallyRunning == false)

        // ...but it must still find the orphan by executable path.
        let discovered = await manager.discoverRunningServer()
        #expect(discovered?.pid == child.processIdentifier)
        #expect(discovered?.isManaged == false)

        let adopted = await manager.adoptDiscoveredServer()
        #expect(adopted?.pid == child.processIdentifier)
        #expect(adopted?.isManaged == true)
        let adoptedIsRunning = await manager.isRunning()
        #expect(adoptedIsRunning)

        // And an unrelated executable is never adopted.
        #expect(ServerProcessDiscovery.runningPIDs(
            matching: FileManager.default.temporaryDirectory
                .appending(path: "not-a-real-llama-server"),
            supportDirectory: FileManager.default.temporaryDirectory
        ).isEmpty)

        try await manager.stop()

        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while child.isRunning, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!child.isRunning)
        let stillRunning = await manager.isRunning()
        #expect(stillRunning == false)
    }

    @Test
    func stopsAServerThatWasNeverAdopted() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = try makeFakeServerBinary(inside: root)
        let config = testConfig(serverBinary: binary, supportDirectory: root)
        let suiteName = "Launcher27B-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let child = Process()
        child.executableURL = binary
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
        }

        let manager = ServerProcessManager(
            config: config,
            defaults: ServerDefaults(defaults),
            apiKeyStore: MemoryAPIKeyStore().store
        )

        try await manager.stopDiscoveredServer()

        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while child.isRunning, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!child.isRunning)
    }

    @Test
    func terminateRefusesAProcessThatIsNotTheLauncherRuntime() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
        }
        try await Task.sleep(for: .milliseconds(100))

        let suiteName = "Launcher27B-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ServerProcessManager(
            config: testConfig(
                serverBinary: root.appending(path: "runtime/mac/llama-server"),
                supportDirectory: root
            ),
            defaults: ServerDefaults(defaults),
            apiKeyStore: MemoryAPIKeyStore().store
        )

        await #expect(throws: ServerProcessError.self) {
            try await manager.terminate(pid: child.processIdentifier)
        }

        // No signal was sent: the unrelated process is still running.
        #expect(Darwin.kill(child.processIdentifier, 0) == 0)
        #expect(child.isRunning)
    }

    /// Re-check the identity immediately before *each* signal, including the one
    /// guarding the
    /// `SIGKILL`. The child ignores `SIGTERM`, so the grace period really does
    /// elapse, and the identity script then reports that the PID is no longer the
    /// process the launcher identified — the signal must be refused.
    @Test
    func terminateRefusesTheForceKillWhenThePidChangedIdentity() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let child = try await makeSigtermIgnoringChild()
        defer { Darwin.kill(child.processIdentifier, SIGKILL) }

        let suiteName = "Launcher27B-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ServerProcessManager(
            config: testConfig(
                serverBinary: root.appending(path: "runtime/mac/llama-server"),
                supportDirectory: root
            ),
            defaults: ServerDefaults(defaults),
            apiKeyStore: MemoryAPIKeyStore().store,
            terminationGracePeriod: .milliseconds(50),
            terminationForceTimeout: .milliseconds(50)
        )
        let script = IdentityScript([.identified, .unrelated])

        await #expect(throws: ServerProcessError.self) {
            try await manager.terminate(pid: child.processIdentifier) {
                await script.next()
            }
        }

        // The SIGKILL was refused, so the SIGTERM-ignoring process is alive.
        #expect(Darwin.kill(child.processIdentifier, 0) == 0)
    }

    /// The escalation itself: an identity that still matches after the grace
    /// period is force-killed.
    @Test
    func terminateEscalatesToSIGKILLWhenTheIdentityStillMatches() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let child = try await makeSigtermIgnoringChild()
        defer { Darwin.kill(child.processIdentifier, SIGKILL) }

        let suiteName = "Launcher27B-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ServerProcessManager(
            config: testConfig(
                serverBinary: root.appending(path: "runtime/mac/llama-server"),
                supportDirectory: root
            ),
            defaults: ServerDefaults(defaults),
            apiKeyStore: MemoryAPIKeyStore().store,
            terminationGracePeriod: .milliseconds(50),
            terminationForceTimeout: .seconds(5)
        )
        let script = IdentityScript([.identified])

        try await manager.terminate(pid: child.processIdentifier) {
            await script.next()
        }

        #expect(Darwin.kill(child.processIdentifier, 0) != 0)
    }

    /// ``ServerProcessManager/stop()`` reached `clearProcessState()` only on the
    /// success path, so a throwing stop left the log-cap task and both log
    /// handles alive (and the PID record behind). The teardown now runs on the
    /// throwing path too; this drives the shared teardown through
    /// ``ServerProcessManager/stopPortListener(_:)``, whose identity check fails
    /// deterministically without any signal being sent.
    @Test
    @MainActor
    func aFailedStopPreservesOwnershipForRetry() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // A listener of our own, so the port re-check finds a live listener that
        // is not the descriptor the user "confirmed".
        let listener = try InProcessListener()

        let binary = try makeScriptRuntime(inside: root, body: """
        #!/bin/sh
        sleep 5
        """)
        try makeRuntimeSupportFiles(inside: root)

        let config = testConfig(
            serverBinary: binary,
            supportDirectory: root,
            chatPort: listener.port
        )
        let suiteName = "Launcher27B-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ServerProcessManager(
            config: config,
            defaults: ServerDefaults(defaults),
            apiKeyStore: MemoryAPIKeyStore().store
        )

        try await manager.start(options: options(bindMode: .loopback))
        #expect(defaults.integer(forKey: "bonsaiServerPID") > 0)

        let wrong = ServerProcessDescriptor(
            pid: getpid() &+ 1,
            executablePath: "/elsewhere/llama-server",
            isManaged: false
        )
        await #expect(throws: ServerProcessError.self) {
            try await manager.stopPortListener(wrong)
        }

        // Failure must retain the running child for a later stop.
        #expect(defaults.integer(forKey: "bonsaiServerPID") > 0)

        try? await manager.stopDiscoveredServer()
        listener.close()
    }

    /// A support root of `/` made every path on the machine look like it lived
    /// inside the launcher's own directory.
    @Test
    func aSupportRootOfSlashNeverMatches() {
        let expected = URL(filePath: "/tmp/runtime/mac/llama-server")

        #expect(!ServerProcessDiscovery.matches(
            executablePath: "/opt/elsewhere/llama-server",
            expectedExecutable: expected,
            supportDirectory: URL(filePath: "/")
        ))
        #expect(ServerProcessDiscovery.runningPIDs(
            matching: expected,
            supportDirectory: URL(filePath: "/")
        ).isEmpty)
    }

    // MARK: - Foreign port owner

    /// `lsof` lookup runs inside `refresh()`, so a stalled probe needs a deadline
    /// to keep the monitoring tick responsive. Exercise it with a slow child and
    /// a 0.2 s limit.
    @Test
    func thePortProbeDeadlineReturnsWithoutWaitingForAStalledChild() async throws {
        let hostedCI = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        let report = ServerPortListenerFinder.PortProbeDeadlineReport()
        let clock = ContinuousClock()
        let start = clock.now

        let data = await ServerPortListenerFinder.output(
            of: URL(filePath: "/bin/sleep"),
            arguments: [hostedCI ? "30" : "5"],
            timeout: .milliseconds(200),
            report: report
        )
        let elapsed = clock.now - start

        #expect(data == nil)
        #expect(report.outcome == .deadlineElapsed)
        #expect(
            elapsed < .seconds(hostedCI ? 10 : 2),
            "the probe waited \(elapsed) instead of its 0.2 s deadline"
        )
    }

    /// The deadline sleeper is cancelled as soon as the child decides the
    /// outcome, so a fast probe does not leave a task parked for the full timeout.
    @Test
    func aProbeWhoseChildExitsDoesNotLeaveItsDeadlineSleeping() async throws {
        let report = ServerPortListenerFinder.PortProbeDeadlineReport()

        let data = await ServerPortListenerFinder.output(
            of: URL(filePath: "/bin/echo"),
            arguments: ["hello"],
            timeout: .seconds(30),
            report: report
        )

        #expect(String(data: try #require(data), encoding: .utf8) == "hello\n")
        // The child won the race, so the 30 s sleeper had to be torn down rather
        // than left parked.
        #expect(report.outcome == .childExited)
        #expect(report.cancelledTimers == 1)
    }

    /// `PendingPortProbes` evicted its ninth retained probe with `removeFirst`,
    /// dropping the last strong reference to a child that was still running —
    /// nothing would then reap it. Evicted live children are kept referenced and
    /// signalled instead.
    @Test
    func anEvictedLiveProbeIsRetainedAndSignalledSoItCanBeReaped() async throws {
        let probes = ServerPortListenerFinder.PendingPortProbes(maximumRetained: 1)

        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            _ = kill(child.processIdentifier, SIGKILL)
            probes.reap(child)
        }
        #expect(child.isRunning)

        probes.retain(child)
        // A second probe overflows the bound; the evicted one is still running.
        probes.retain(Process())

        #expect(probes.evictedLiveChildCount == 1)

        // Being evicted did not orphan it: it was signalled, so it exits.
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while child.isRunning, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!child.isRunning, "the evicted live child was not signalled")
    }

    /// The identity check that guards the signal must match on *both* the PID and
    /// the executable path, and must report a vanished listener as gone.
    @Test
    @MainActor
    func portIdentityOnlyMatchesTheConfirmedListener() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let listener = try InProcessListener()

        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let config = LauncherConfig(
            serverBinary: support.appending(path: "runtime/mac/llama-server"),
            modelFile: support.appending(path: "models/27B/model.gguf"),
            projectorFile: support.appending(path: "models/27B/mmproj.gguf"),
            ablationAdapterFile: support.appending(path: "modules/adapter.gguf"),
            webUIConfigFile: support.appending(path: "webui-config.json"),
            chatURL: URL(string: "http://127.0.0.1:\(listener.port)/")!,
            contextSize: "1024",
            reasoningBudget: "128",
            logDirectory: root.appending(path: "logs")
        )
        let suiteName = "Launcher27B-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ServerProcessManager(
            config: config,
            defaults: ServerDefaults(defaults),
            apiKeyStore: MemoryAPIKeyStore().store
        )

        let ownerPath = ServerProcessDiscovery.executablePath(of: getpid()) ?? ""
        let confirmed = ServerProcessDescriptor(
            pid: getpid(),
            executablePath: ownerPath,
            isManaged: false
        )
        #expect(await manager.portIdentity(of: confirmed) == .identified)

        // The confirmed descriptor names a different PID.
        let reusedPID = ServerProcessDescriptor(
            pid: getpid() &+ 1,
            executablePath: ownerPath,
            isManaged: false
        )
        #expect(await manager.portIdentity(of: reusedPID) == .unrelated)

        // Same PID, but the executable is no longer the one that was confirmed.
        let wrongExecutable = ServerProcessDescriptor(
            pid: getpid(),
            executablePath: "/somewhere/else/llama-server",
            isManaged: false
        )
        #expect(await manager.portIdentity(of: wrongExecutable) == .unrelated)

        // Nothing listens any more.
        listener.close()
        #expect(await manager.portIdentity(of: confirmed) == .gone)
    }

    /// A healthy listener that is *not* the launcher's binary is identified through
    /// the port so the card can explain the conflict and offer to release it without
    /// adopting it.
    @Test
    @MainActor
    func aHealthyListenerThatIsNotOurBinaryIsStillActionable() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // The test process itself listens, so the owner is provably not the
        // launcher's runtime binary.
        let listener = try InProcessListener()
        defer { listener.close() }

        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let config = LauncherConfig(
            serverBinary: support.appending(path: "runtime/mac/llama-server"),
            modelFile: support.appending(path: "models/27B/model.gguf"),
            projectorFile: support.appending(path: "models/27B/mmproj.gguf"),
            ablationAdapterFile: support.appending(path: "modules/adapter.gguf"),
            webUIConfigFile: support.appending(path: "webui-config.json"),
            chatURL: URL(string: "http://127.0.0.1:\(listener.port)/")!,
            contextSize: "1024",
            reasoningBudget: "128",
            logDirectory: root.appending(path: "logs")
        )
        let suiteName = "Launcher27B-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ServerProcessManager(
            config: config,
            defaults: ServerDefaults(defaults),
            apiKeyStore: MemoryAPIKeyStore().store
        )
        let controller = ServiceController(
            config: config,
            requiresInstanceLock: false, preferences: TestPreferences.chinese(),
            processManager: manager,
            metricsClient: unreachableMetricsClient(),
            defaults: defaults,
            healthProbe: { _ in true },
            loginItemStatus: { .notRegistered }
        )

        await controller.refresh()

        #expect(controller.status == .external)

        // It is not our binary, so it can never be adopted …
        let discovered = await manager.discoverRunningServer()
        #expect(discovered == nil)

        // … but the user is not left with zero affordances.
        #expect(controller.unownedServer?.pid == getpid())
        #expect(controller.canStopUnownedServer)
    }

    // MARK: - Helpers

    /// A `LlamaMetricsClient` whose requests fail immediately: the tests that
    /// point the controller at a stub listener must not wait out the real 1.5 s
    /// `/metrics` timeout.
    private func unreachableMetricsClient() -> LlamaMetricsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.05
        return LlamaMetricsClient(
            session: URLSession(configuration: configuration)
        )
    }

    /// A TCP listener owned by the test process, so `lsof` reports this process
    /// as the port's owner.
    private final class InProcessListener {
        let port: Int
        private let descriptor: Int32

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ListenerError.socketFailed }

            var reuse: Int32 = 1
            _ = setsockopt(
                fd,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuse,
                socklen_t(MemoryLayout<Int32>.size)
            )

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 4) == 0 else {
                Darwin.close(fd)
                throw ListenerError.bindFailed
            }

            var assigned = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &assigned) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &length)
                }
            }
            guard named == 0 else {
                Darwin.close(fd)
                throw ListenerError.bindFailed
            }

            descriptor = fd
            port = Int(UInt16(bigEndian: assigned.sin_port))
        }

        func close() {
            Darwin.close(descriptor)
        }
    }

    private enum ListenerError: Error {
        case socketFailed
        case bindFailed
    }

    private func size(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try #require(attributes[.size] as? NSNumber)
        return number.intValue
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try #require(attributes[.posixPermissions] as? NSNumber)
        return number.intValue
    }

    /// A stand-in runtime at the path the launcher expects, so `start()` can
    /// spawn a real child that writes to the inherited log descriptor.
    private func makeScriptRuntime(inside support: URL, body: String) throws -> URL {
        let directory = support.appending(path: "runtime/mac", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let binary = directory.appending(path: "llama-server")
        try body.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path
        )
        return binary
    }

    /// The non-executable files `ServerProcessManager.start()` insists on.
    private func makeRuntimeSupportFiles(inside support: URL) throws {
        try FileManager.default.createDirectory(
            at: support.appending(path: "modules/orcabonsai", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        for path in ["webui-config.json", "modules/orcabonsai/adapter.gguf"] {
            try Data("{}".utf8).write(to: support.appending(path: path))
        }
    }

    private func options(bindMode: ServerBindMode) -> ServerLaunchOptions {
        ServerLaunchOptions(
            ablationEnabled: false,
            ablationStrength: .exact,
            bindMode: bindMode
        )
    }

    private func testConfig(
        serverBinary: URL? = nil,
        supportDirectory: URL? = nil,
        chatPort: Int = 8080
    ) -> LauncherConfig {
        let binary = serverBinary
            ?? URL(fileURLWithPath: "/tmp/runtime/mac/llama-server")
        let support = supportDirectory ?? URL(fileURLWithPath: "/tmp")

        return LauncherConfig(
            serverBinary: binary,
            modelFile: support.appending(path: "models/27B/model.gguf"),
            projectorFile: support.appending(path: "models/27B/mmproj.gguf"),
            ablationAdapterFile: support.appending(path: "modules/orcabonsai/adapter.gguf"),
            webUIConfigFile: support.appending(path: "webui-config.json"),
            chatURL: URL(string: "http://127.0.0.1:\(chatPort)/")!,
            contextSize: "32768",
            reasoningBudget: "2048",
            logDirectory: support.appending(path: "logs")
        )
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "Launcher27B-security-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A child that ignores `SIGTERM`, so `terminate` really does wait out its
    /// grace period and reach the `SIGKILL` decision.
    ///
    /// `trap '' TERM; exec sleep 30` leaves a single process: `SIG_IGN` survives
    /// `exec`, so the replacement `sleep` keeps ignoring `SIGTERM`.
    private func makeSigtermIgnoringChild() async throws -> Process {
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sh")
        child.arguments = ["-c", "trap '' TERM; exec sleep 30"]
        try child.run()
        // Let `sh` install the trap and `exec` before any signal is sent.
        try await Task.sleep(for: .milliseconds(150))
        return child
    }

    /// A harmless stand-in for `llama-server`: a copy of `sleep` placed at the
    /// runtime path the launcher expects, so discovery, adoption and stopping
    /// can be exercised without touching the real runtime binary.
    ///
    /// macOS SIGKILLs a *relocated* platform binary at exec, so the copy is
    /// re-signed ad-hoc to turn it into an ordinary executable.
    private func makeFakeServerBinary(inside support: URL) throws -> URL {
        let directory = support.appending(path: "runtime/mac", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let binary = directory.appending(path: "llama-server")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: binary.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path
        )

        try runCodesign(["--remove-signature", binary.path])
        try runCodesign(["-s", "-", binary.path])
        return binary
    }

    private func runCodesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw FakeServerBinaryError.codesignFailed(status: process.terminationStatus)
        }
    }
}

private enum FakeServerBinaryError: Error {
    case codesignFailed(status: Int32)
}

/// Returns a scripted sequence of identity answers, repeating the last one once
/// the script is exhausted, so a test can decide what `terminate` sees at each
/// re-check.
private actor IdentityScript {
    private let values: [ServerProcessManager.TargetIdentity]
    private var index = 0

    init(_ values: [ServerProcessManager.TargetIdentity]) {
        self.values = values
    }

    func next() -> ServerProcessManager.TargetIdentity {
        guard !values.isEmpty else { return .unrelated }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}
