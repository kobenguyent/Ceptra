import XCTest
@testable import CeptraCore

final class AISecurityAndBridgeTests: XCTestCase {
    func testAppSettingsJSONAndConversationStoreNeverContainSecrets() throws {
        let secret = "sk-ant-api03-TESTSECRETVALUE999988887777"
        let secretStore = InMemoryAISecretStore()
        let profile = AIProviderProfile(name: "Claude Prod", kind: .anthropic, modelID: "claude-sonnet-4-5")
        try secretStore.saveSecret(secret, forProfileID: profile.id)

        var settings = AppSettings()
        settings.aiSettings = AISettings(
            profiles: [profile],
            activeProfileID: profile.id,
            bridgeToCodeceptAI: false,
            redactSecretsInCloudContext: true
        )

        let encoded = try JSONEncoder().encode(settings)
        let jsonString = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(jsonString.contains(secret))
        XCTAssertFalse(jsonString.lowercased().contains("apikey"))

        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertEqual(decoded.aiSettings.profiles.count, 1)
        XCTAssertEqual(decoded.aiSettings.activeProfile?.id, profile.id)
        XCTAssertEqual(secretStore.loadSecret(forProfileID: profile.id), secret)

        // Conversation store also strips secrets before writing to disk
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-ai-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AIConversationStore(baseDirectory: tempDir)
        let session = AIChatSession(
            title: "Debug test",
            workspacePath: "/tmp/demo",
            messages: [
                AIChatMessage(role: .user, content: "Help debug key \(secret) and Authorization: Bearer mySuperSecretToken123456")
            ]
        )
        store.saveSessions([session], forWorkspacePath: "/tmp/demo", explicitSecretsToStrip: [secret])

        let savedFiles = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(savedFiles.count, 1)
        let rawOnDisk = try String(contentsOf: savedFiles[0], encoding: .utf8)
        XCTAssertFalse(rawOnDisk.contains(secret))
        XCTAssertFalse(rawOnDisk.contains("mySuperSecretToken123456"))
    }

    func testSecretRedactorScrubsProviderKeysBearersCookiesAndEnvPasswords() {
        let syntheticJWT = ["eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiIxMjM0NTY3ODkwIn0", "signature123456"].joined(separator: ".")
        let input = """
        OPENAI_API_KEY=sk-proj-abc1234567890XYZ987654
        ANTHROPIC_KEY="sk-ant-1234567890abcdef1234"
        GOOGLE_KEY=AIzaSyA1234567890abcdefghij1234567
        GH=ghp_1234567890abcdefghijklmnop
        Authorization: Bearer \(syntheticJWT)
        Cookie: session_id=supersecretcookie; theme=dark
        DB_PASSWORD=myStrongPassword!42
        """
        let result = AISecretRedactor.redact(input)
        XCTAssertTrue(result.wasRedacted)
        XCTAssertGreaterThanOrEqual(result.redactionCount, 6)
        XCTAssertFalse(result.text.contains("sk-proj-"))
        XCTAssertFalse(result.text.contains("sk-ant-"))
        XCTAssertFalse(result.text.contains("AIzaSy"))
        XCTAssertFalse(result.text.contains("ghp_123456"))
        XCTAssertFalse(result.text.contains("eyJhbGci"))
        XCTAssertFalse(result.text.contains("supersecretcookie"))
        XCTAssertFalse(result.text.contains("myStrongPassword!42"))
    }

    func testURLValidatorBlocksInsecureRemoteHTTPFileURLsEmbeddedCredsAndMetadataIPs() throws {
        // Loopback HTTP allowed
        let ollama = try AIURLValidator.validateBaseURL("http://127.0.0.1:11434/")
        XCTAssertEqual(ollama.absoluteString, "http://127.0.0.1:11434")
        let localhost = try AIURLValidator.validateBaseURL("http://localhost:1234/v1/")
        XCTAssertEqual(localhost.absoluteString, "http://localhost:1234/v1")

        // Remote HTTPS allowed
        let claude = try AIURLValidator.validateBaseURL("https://api.anthropic.com/")
        XCTAssertEqual(claude.absoluteString, "https://api.anthropic.com")

        // Remote HTTP blocked by default
        XCTAssertThrowsError(try AIURLValidator.validateBaseURL("http://api.openai.com/v1")) { err in
            XCTAssertEqual(err as? AIProviderError, .insecureRemoteURL("api.openai.com"))
        }

        // Private LAN HTTP blocked by default, allowed ONLY with opt-in flag
        XCTAssertThrowsError(try AIURLValidator.validateBaseURL("http://192.168.1.50:11434"))
        let lan = try AIURLValidator.validateBaseURL("http://192.168.1.50:11434", allowInsecureLocalHTTP: true)
        XCTAssertEqual(lan.absoluteString, "http://192.168.1.50:11434")

        // Public host STILL blocked even with allowInsecureLocalHTTP = true
        XCTAssertThrowsError(try AIURLValidator.validateBaseURL("http://evil.example.com/v1", allowInsecureLocalHTTP: true))

        // file://, embedded creds, and cloud metadata IPs blocked unconditionally
        XCTAssertThrowsError(try AIURLValidator.validateBaseURL("file:///etc/passwd"))
        XCTAssertThrowsError(try AIURLValidator.validateBaseURL("https://user:secret@api.openai.com/v1"))
        XCTAssertThrowsError(try AIURLValidator.validateBaseURL("http://169.254.169.254/latest/meta-data", allowInsecureLocalHTTP: true))
        XCTAssertThrowsError(try AIURLValidator.validateBaseURL("https://metadata.google.internal/computeMetadata", allowInsecureLocalHTTP: true))
    }

    func testSameOriginRedirectValidationBlocksCrossOriginAndDowngrade() {
        let a = URL(string: "https://api.openai.com/v1/chat/completions")!
        let b = URL(string: "https://api.openai.com/v1/chat/completions?foo=1")!
        let crossHost = URL(string: "https://attacker.example/steal")!
        let downgrade = URL(string: "http://api.openai.com/v1/chat/completions")!
        let diffPort = URL(string: "https://api.openai.com:8443/v1/chat/completions")!

        XCTAssertTrue(AIURLValidator.isSameOrigin(a, b))
        XCTAssertFalse(AIURLValidator.isSameOrigin(a, crossHost))
        XCTAssertFalse(AIURLValidator.isSameOrigin(a, downgrade))
        XCTAssertFalse(AIURLValidator.isSameOrigin(a, diffPort))
    }

    func testCodeceptAIBridgeFailsClosedByDefaultAndNeverLeaksSecretsIntoDisplayOrTerminalCommands() throws {
        let secret = "sk-live-secret-bridge-token-99999"
        let store = InMemoryAISecretStore()
        let profile = AIProviderProfile(name: "OpenAI", kind: .openAI, modelID: "gpt-4.1")
        try store.saveSecret(secret, forProfileID: profile.id)

        var aiSettings = AISettings(profiles: [profile], activeProfileID: profile.id)
        var runOptions = RunOptions()
        runOptions.aiEnabled = true

        // 1. Fail-closed by default (bridgeToCodeceptAI == false)
        let disabledResult = AICodeceptBridge.buildBridgeEnvironment(
            settings: aiSettings,
            runOptions: runOptions,
            consoleExecutionMode: .builtIn,
            secretStore: store
        )
        XCTAssertTrue(disabledResult.secretEnvironment.isEmpty)

        // 2. Enabled in System Terminal mode -> refuses to inject secrets and returns warning
        aiSettings.bridgeToCodeceptAI = true
        let systemTermResult = AICodeceptBridge.buildBridgeEnvironment(
            settings: aiSettings,
            runOptions: runOptions,
            consoleExecutionMode: .systemTerminal,
            secretStore: store
        )
        XCTAssertTrue(systemTermResult.secretEnvironment.isEmpty)
        XCTAssertNotNil(systemTermResult.systemTerminalSkippedWarning)

        // 3. Enabled in Built-in Console mode -> injects ONLY into Process.environment, NEVER into displayCommand or environmentOverrides
        let builtInResult = AICodeceptBridge.buildBridgeEnvironment(
            settings: aiSettings,
            runOptions: runOptions,
            consoleExecutionMode: .builtIn,
            secretStore: store
        )
        XCTAssertEqual(builtInResult.secretEnvironment["OPENAI_API_KEY"], secret)
        XCTAssertEqual(builtInResult.secretEnvironment["CEPTRA_AI_MODEL"], "gpt-4.1")

        let root = FileManager.default.temporaryDirectory
        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: root)
        let cmd = CommandBuilder.build(
            mode: .runAll,
            options: runOptions,
            workspaceRoot: root,
            toolchain: toolchain,
            secretEnvironmentOverrides: builtInResult.secretEnvironment
        )
        XCTAssertEqual(cmd.environment["OPENAI_API_KEY"], secret)
        XCTAssertNil(cmd.environmentOverrides["OPENAI_API_KEY"])
        XCTAssertFalse(cmd.displayCommand.contains(secret))

        // 4. Config snippet uses process.env.*, never hardcoded secrets
        let snippet = AICodeceptBridge.configSnippet(for: profile)
        XCTAssertTrue(snippet.contains("process.env.OPENAI_API_KEY"))
        XCTAssertFalse(snippet.contains(secret))
    }

    func testConversationStoreSkipsEmptyDraftsAndClearsFileWhenEmptied() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ceptra-conv-clean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = AIConversationStore(baseDirectory: tmpDir)
        let ws = "/tmp/ws-chat-cleanup"

        let empty1 = AIChatSession(title: "New Chat", workspacePath: ws, messages: [])
        let empty2 = AIChatSession(title: "New Chat", workspacePath: ws, messages: [])
        let real = AIChatSession(
            title: "Fix login test",
            workspacePath: ws,
            messages: [AIChatMessage(role: .user, content: "Help fix #submit")]
        )

        store.saveSessions([empty1, real, empty2], forWorkspacePath: ws)
        let loaded = store.loadSessions(forWorkspacePath: ws)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Fix login test")

        // Saving only empty drafts clears persisted history cleanly
        store.saveSessions([empty1], forWorkspacePath: ws)
        XCTAssertTrue(store.loadSessions(forWorkspacePath: ws).isEmpty)
    }
}
