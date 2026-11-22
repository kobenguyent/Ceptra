import Foundation

/// Opt-in bridge connecting Ceptra's active AI provider to CodeceptJS's built-in `--ai` / `heal` plugins.
/// Security invariant: fails closed (`bridgeToCodeceptAI == false`), and secret env vars are ONLY injected
/// into Built-in Console child processes — NEVER into System Terminal scripts or `displayCommand`.
public enum AICodeceptBridge {
    public struct BridgeResult: Equatable, Sendable {
        public let secretEnvironment: [String: String]
        public let systemTerminalSkippedWarning: String?

        public init(secretEnvironment: [String: String] = [:], systemTerminalSkippedWarning: String? = nil) {
            self.secretEnvironment = secretEnvironment
            self.systemTerminalSkippedWarning = systemTerminalSkippedWarning
        }
    }

    public static func buildBridgeEnvironment(
        settings: AISettings,
        runOptions: RunOptions,
        consoleExecutionMode: ConsoleExecutionMode,
        secretStore: AISecretStore
    ) -> BridgeResult {
        guard settings.bridgeToCodeceptAI else {
            return BridgeResult()
        }

        let needsAI = runOptions.aiEnabled || runOptions.enabledPlugins.contains(where: {
            let lower = $0.lowercased()
            return lower == "heal" || lower == "aitrace"
        })
        guard needsAI, let profile = settings.activeProfile, !profile.kind.isCLI else {
            return BridgeResult()
        }

        if consoleExecutionMode == .systemTerminal {
            return BridgeResult(
                secretEnvironment: [:],
                systemTerminalSkippedWarning: "AI provider credentials were not passed to System Terminal to prevent leaking secrets in shell commands. Switch to Built-in Console to bridge Ceptra's Keychain credentials into CodeceptJS --ai."
            )
        }

        var env: [String: String] = [
            "CEPTRA_AI_PROVIDER": profile.kind.rawValue,
            "CEPTRA_AI_MODEL": profile.modelID
        ]
        if let validURL = try? AIURLValidator.validateBaseURL(
            profile.baseURL,
            allowInsecureLocalHTTP: profile.allowInsecureLocalHTTP
        ) {
            env["CEPTRA_AI_BASE_URL"] = validURL.absoluteString
            if profile.kind == .ollama {
                env["OLLAMA_HOST"] = validURL.absoluteString
            }
        }

        if let key = secretStore.loadSecret(forProfileID: profile.id)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            switch profile.kind {
            case .openAI, .openAICompatible:
                env["OPENAI_API_KEY"] = key
            case .anthropic:
                env["ANTHROPIC_API_KEY"] = key
            case .gemini:
                env["GEMINI_API_KEY"] = key
            case .githubModels:
                env["GITHUB_TOKEN"] = key
                env["OPENAI_API_KEY"] = key
            case .ollama:
                env["OLLAMA_API_KEY"] = key
            case .claudeCLI, .copilotCLI, .codexCLI:
                break
            }
        }

        return BridgeResult(secretEnvironment: env)
    }

    /// Generates a safe `codecept.conf.ts` / `codecept.conf.js` `ai: { request }` snippet
    /// that reads exclusively from `process.env.*` (zero hardcoded API keys).
    public static func configSnippet(for profile: AIProviderProfile) -> String {
        switch profile.kind {
        case .ollama:
            return """
            // Add to codecept.conf.ts / codecept.conf.js (reads OLLAMA_HOST & CEPTRA_AI_MODEL from Ceptra)
            ai: {
              request: async (messages) => {
                const host = process.env.OLLAMA_HOST || '\(profile.baseURL)';
                const model = process.env.CEPTRA_AI_MODEL || '\(profile.modelID)';
                const res = await fetch(`${host}/api/chat`, {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ model, messages, stream: false }),
                });
                const json = await res.json();
                return json?.message?.content || '';
              },
            },
            """

        case .anthropic:
            return """
            // Add to codecept.conf.ts / codecept.conf.js (reads ANTHROPIC_API_KEY from Ceptra Keychain bridge)
            ai: {
              request: async (messages) => {
                const res = await fetch('https://api.anthropic.com/v1/messages', {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'application/json',
                    'x-api-key': process.env.ANTHROPIC_API_KEY || '',
                    'anthropic-version': '2023-06-01',
                  },
                  body: JSON.stringify({
                    model: process.env.CEPTRA_AI_MODEL || '\(profile.modelID)',
                    max_tokens: 4096,
                    messages,
                  }),
                });
                const json = await res.json();
                return json?.content?.[0]?.text || '';
              },
            },
            """

        case .gemini:
            return """
            // Add to codecept.conf.ts / codecept.conf.js (reads GEMINI_API_KEY from Ceptra Keychain bridge)
            ai: {
              request: async (messages) => {
                const model = process.env.CEPTRA_AI_MODEL || '\(profile.modelID)';
                const prompt = messages.map((m) => `${m.role}: ${m.content}`).join('\\n\\n');
                const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'application/json',
                    'x-goog-api-key': process.env.GEMINI_API_KEY || '',
                  },
                  body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }] }),
                });
                const json = await res.json();
                return json?.candidates?.[0]?.content?.parts?.[0]?.text || '';
              },
            },
            """

        case .openAI, .githubModels, .openAICompatible:
            let envKey = profile.kind == .githubModels ? "process.env.GITHUB_TOKEN || process.env.OPENAI_API_KEY" : "process.env.OPENAI_API_KEY"
            let baseExpr = "process.env.CEPTRA_AI_BASE_URL || '\(profile.baseURL)'"
            return """
            // Add to codecept.conf.ts / codecept.conf.js (reads key from Ceptra Keychain bridge)
            ai: {
              request: async (messages) => {
                const baseURL = \(baseExpr);
                const res = await fetch(`${baseURL}/chat/completions`, {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${\(envKey) || ''}`,
                  },
                  body: JSON.stringify({
                    model: process.env.CEPTRA_AI_MODEL || '\(profile.modelID)',
                    messages,
                  }),
                });
                const json = await res.json();
                return json?.choices?.[0]?.message?.content || '';
              },
            },
            """

        case .claudeCLI, .copilotCLI, .codexCLI:
            return """
            // Local CLI providers (\(profile.kind.displayName)) power Ceptra's built-in AI Assistant directly.
            // For CodeceptJS CLI `--ai` / `heal` runs, select an HTTP provider (Ollama, Claude, OpenAI, Gemini, or GitHub Models).
            """
        }
    }
}
