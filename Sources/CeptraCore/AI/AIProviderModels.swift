import Foundation

public enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case ollama
    case anthropic
    case openAI
    case gemini
    case githubModels
    case openAICompatible
    case claudeCLI
    case copilotCLI
    case codexCLI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama (Local)"
        case .anthropic: return "Anthropic (Claude)"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .githubModels: return "GitHub Models"
        case .openAICompatible: return "OpenAI-Compatible"
        case .claudeCLI: return "Claude Code CLI"
        case .copilotCLI: return "GitHub Copilot CLI"
        case .codexCLI: return "OpenAI Codex CLI"
        }
    }

    public var shortName: String {
        switch self {
        case .ollama: return "Ollama"
        case .anthropic: return "Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .githubModels: return "GitHub"
        case .openAICompatible: return "Custom"
        case .claudeCLI: return "Claude CLI"
        case .copilotCLI: return "Copilot CLI"
        case .codexCLI: return "Codex CLI"
        }
    }

    public var symbolName: String {
        switch self {
        case .ollama: return "desktopcomputer"
        case .anthropic: return "sparkles"
        case .openAI: return "cpu"
        case .gemini: return "diamond"
        case .githubModels: return "chevron.left.forwardslash.chevron.right"
        case .openAICompatible: return "network"
        case .claudeCLI, .copilotCLI, .codexCLI: return "terminal"
        }
    }

    public var isCLI: Bool {
        switch self {
        case .claudeCLI, .copilotCLI, .codexCLI:
            return true
        default:
            return false
        }
    }

    public var isLocalByDefault: Bool {
        switch self {
        case .ollama, .claudeCLI, .copilotCLI, .codexCLI:
            return true
        default:
            return false
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .anthropic, .openAI, .gemini, .githubModels:
            return true
        case .ollama, .openAICompatible, .claudeCLI, .copilotCLI, .codexCLI:
            return false
        }
    }

    public var supportsAPIKey: Bool {
        !isCLI
    }

    public var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://127.0.0.1:11434"
        case .anthropic: return "https://api.anthropic.com"
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .githubModels: return "https://models.github.ai/inference"
        case .openAICompatible: return "http://127.0.0.1:1234/v1"
        case .claudeCLI, .copilotCLI, .codexCLI: return ""
        }
    }

    public var defaultModelID: String {
        switch self {
        case .ollama: return "qwen2.5-coder:7b"
        case .anthropic: return "claude-sonnet-4-5"
        case .openAI: return "gpt-4.1"
        case .gemini: return "gemini-2.5-flash"
        case .githubModels: return "openai/gpt-4.1"
        case .openAICompatible: return "local-model"
        case .claudeCLI: return "sonnet"
        case .copilotCLI: return "default"
        case .codexCLI: return "default"
        }
    }

    public var curatedModels: [String] {
        switch self {
        case .ollama:
            return ["qwen2.5-coder:7b", "qwen2.5-coder:14b", "llama3.2", "deepseek-coder-v2", "codellama"]
        case .anthropic:
            return ["claude-sonnet-4-5", "claude-opus-4-1", "claude-3-7-sonnet-latest", "claude-3-5-haiku-latest"]
        case .openAI:
            return ["gpt-4.1", "gpt-4.1-mini", "gpt-4o", "o4-mini"]
        case .gemini:
            return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .githubModels:
            return ["openai/gpt-4.1", "openai/gpt-4o", "anthropic/claude-3.7-sonnet", "meta/llama-3.3-70b-instruct"]
        case .openAICompatible:
            return ["local-model"]
        case .claudeCLI:
            return ["sonnet", "opus", "haiku"]
        case .copilotCLI:
            return ["default"]
        case .codexCLI:
            return ["default", "o4-mini", "gpt-4.1"]
        }
    }

    public var apiKeyLabel: String {
        switch self {
        case .githubModels: return "GitHub Token (models:read)"
        case .anthropic: return "Anthropic API Key"
        case .openAI: return "OpenAI API Key"
        case .gemini: return "Gemini API Key"
        case .ollama: return "Optional Bearer Token"
        case .openAICompatible: return "API Key (optional for local servers)"
        case .claudeCLI, .copilotCLI, .codexCLI: return "Uses Local CLI Sign-In"
        }
    }

    public var cliExecutableNames: [String] {
        switch self {
        case .claudeCLI: return ["claude"]
        case .copilotCLI: return ["copilot", "gh"]
        case .codexCLI: return ["codex"]
        default: return []
        }
    }

    public var setupBadgeText: String? {
        switch self {
        case .gemini: return "Free tier"
        default: return nil
        }
    }

    public var apiKeyConsoleURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .githubModels: return URL(string: "https://github.com/settings/personal-access-tokens")
        default: return nil
        }
    }

    public var apiKeySetupHint: String {
        switch self {
        case .anthropic:
            return "Create an API key in Anthropic Console. Stored strictly in macOS Keychain."
        case .openAI:
            return "Create a secret API key in OpenAI Platform. Stored strictly in macOS Keychain."
        case .gemini:
            return "Free tier available in Google AI Studio — no credit card needed to get started."
        case .githubModels:
            return "Create a fine-grained GitHub PAT with the `models:read` permission."
        case .ollama:
            return "Runs 100% locally on your Mac — no API key required."
        case .openAICompatible:
            return "Pick a preset below or enter any OpenAI-compatible gateway URL."
        case .claudeCLI, .copilotCLI, .codexCLI:
            return "Reuses your existing local CLI sign-in — no API key required in Ceptra."
        }
    }

    public var cliInstallCommand: String? {
        switch self {
        case .claudeCLI: return "npm install -g @anthropic-ai/claude-code"
        case .copilotCLI: return "gh extension install github/gh-copilot"
        case .codexCLI: return "npm install -g @openai/codex"
        default: return nil
        }
    }

    public var cliLoginCommand: String? {
        switch self {
        case .claudeCLI: return "claude"
        case .copilotCLI: return "gh auth login"
        case .codexCLI: return "codex"
        default: return nil
        }
    }

    public var cliDocsURL: URL? {
        switch self {
        case .claudeCLI: return URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")
        case .copilotCLI: return URL(string: "https://docs.github.com/en/copilot/using-github-copilot/using-github-copilot-in-the-command-line")
        case .codexCLI: return URL(string: "https://github.com/openai/codex")
        default: return nil
        }
    }

    public var helpSubtitle: String {
        switch self {
        case .ollama:
            return "Runs 100% locally via Ollama (/api/tags & /api/chat). No API key needed."
        case .anthropic:
            return "Direct Anthropic Messages API. API key stored securely in macOS Keychain."
        case .openAI:
            return "Direct OpenAI Chat Completions API. API key stored securely in macOS Keychain."
        case .gemini:
            return "Google Gemini streaming API via x-goog-api-key header (never in URL)."
        case .githubModels:
            return "GitHub Models inference API using a GitHub PAT with models:read scope."
        case .openAICompatible:
            return "1-click presets for LM Studio, OpenRouter, Groq, DeepSeek, or custom gateways."
        case .claudeCLI:
            return "Uses your locally signed-in `claude` CLI in read-only print mode (no separate API key)."
        case .copilotCLI:
            return "Uses your locally signed-in `copilot` or `gh copilot` CLI in non-interactive mode."
        case .codexCLI:
            return "Uses your locally signed-in `codex` CLI in read-only sandbox mode."
        }
    }
}

public struct OpenAICompatiblePreset: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let requiresAPIKey: Bool
    public let portalURL: URL?
    public let portalButtonTitle: String?
    public let hint: String
    public let defaultModels: [String]

    public init(
        id: String,
        name: String,
        baseURL: String,
        requiresAPIKey: Bool,
        portalURL: URL?,
        portalButtonTitle: String?,
        hint: String,
        defaultModels: [String]
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.requiresAPIKey = requiresAPIKey
        self.portalURL = portalURL
        self.portalButtonTitle = portalButtonTitle
        self.hint = hint
        self.defaultModels = defaultModels
    }

    public static let allPresets: [OpenAICompatiblePreset] = [
        OpenAICompatiblePreset(
            id: "lmstudio",
            name: "LM Studio",
            baseURL: "http://127.0.0.1:1234/v1",
            requiresAPIKey: false,
            portalURL: URL(string: "https://lmstudio.ai"),
            portalButtonTitle: "Download LM Studio",
            hint: "Runs locally on port 1234. Start the Local Server in LM Studio — no API key needed.",
            defaultModels: ["qwen2.5-coder-7b-instruct", "llama-3.2-3b-instruct"]
        ),
        OpenAICompatiblePreset(
            id: "openrouter",
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            requiresAPIKey: true,
            portalURL: URL(string: "https://openrouter.ai/keys"),
            portalButtonTitle: "Get OpenRouter Key",
            hint: "Access 200+ top coding models through one API key stored securely in macOS Keychain.",
            defaultModels: ["anthropic/claude-sonnet-4", "openai/gpt-4.1", "google/gemini-2.5-pro", "deepseek/deepseek-chat"]
        ),
        OpenAICompatiblePreset(
            id: "groq",
            name: "Groq",
            baseURL: "https://api.groq.com/openai/v1",
            requiresAPIKey: true,
            portalURL: URL(string: "https://console.groq.com/keys"),
            portalButtonTitle: "Get Groq Key",
            hint: "Ultra-fast inference with a generous free developer tier.",
            defaultModels: ["llama-3.3-70b-versatile", "qwen-qwq-32b", "llama-3.1-8b-instant"]
        ),
        OpenAICompatiblePreset(
            id: "deepseek",
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            requiresAPIKey: true,
            portalURL: URL(string: "https://platform.deepseek.com/api_keys"),
            portalButtonTitle: "Get DeepSeek Key",
            hint: "High-value coding and reasoning models via OpenAI-compatible API.",
            defaultModels: ["deepseek-chat", "deepseek-reasoner"]
        ),
        OpenAICompatiblePreset(
            id: "custom",
            name: "Custom",
            baseURL: "http://127.0.0.1:8080/v1",
            requiresAPIKey: false,
            portalURL: nil,
            portalButtonTitle: nil,
            hint: "Works with vLLM, LiteLLM, Jan, llama.cpp, or any OpenAI-compatible gateway.",
            defaultModels: ["local-model"]
        )
    ]

    public static func matchingPreset(for baseURL: String) -> OpenAICompatiblePreset {
        let lower = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("1234") { return allPresets[0] }
        if lower.contains("openrouter.ai") { return allPresets[1] }
        if lower.contains("groq.com") { return allPresets[2] }
        if lower.contains("deepseek.com") { return allPresets[3] }
        return allPresets[4]
    }
}

/// Non-secret metadata for a configured AI provider profile.
/// API keys are NEVER stored in this struct; they live exclusively in macOS Keychain keyed by `id`.
public struct AIProviderProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: AIProviderKind
    public var baseURL: String
    public var modelID: String
    public var availableModels: [String]
    public var customCLIPath: String
    public var allowInsecureLocalHTTP: Bool
    public var temperature: Double
    public var maxTokens: Int

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        kind: AIProviderKind,
        baseURL: String? = nil,
        modelID: String? = nil,
        availableModels: [String]? = nil,
        customCLIPath: String = "",
        allowInsecureLocalHTTP: Bool = false,
        temperature: Double = 0.2,
        maxTokens: Int = 4096
    ) {
        self.id = id
        self.name = name ?? kind.displayName
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.modelID = modelID ?? (kind == .ollama ? "" : kind.defaultModelID)
        self.availableModels = availableModels ?? (kind == .ollama ? [] : kind.curatedModels)
        self.customCLIPath = customCLIPath
        self.allowInsecureLocalHTTP = allowInsecureLocalHTTP
        self.temperature = min(max(temperature, 0.0), 2.0)
        self.maxTokens = min(max(maxTokens, 256), 32768)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(AIProviderKind.self, forKey: .kind) ?? .ollama
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? kind.displayName
        self.kind = kind
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? kind.defaultBaseURL
        self.modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? kind.defaultModelID
        self.availableModels = try c.decodeIfPresent([String].self, forKey: .availableModels) ?? kind.curatedModels
        self.customCLIPath = try c.decodeIfPresent(String.self, forKey: .customCLIPath) ?? ""
        self.allowInsecureLocalHTTP = try c.decodeIfPresent(Bool.self, forKey: .allowInsecureLocalHTTP) ?? false
        self.temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.2
        self.maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 4096
    }

    public var sendsDataToCloud: Bool {
        switch kind {
        case .ollama:
            return !AIURLValidator.isLoopbackBaseURL(baseURL)
        case .openAICompatible:
            return !AIURLValidator.isLoopbackBaseURL(baseURL)
        case .anthropic, .openAI, .gemini, .githubModels, .claudeCLI, .copilotCLI, .codexCLI:
            return true
        }
    }

    public static func defaultOllamaProfile() -> AIProviderProfile {
        AIProviderProfile(
            name: "Local Ollama",
            kind: .ollama,
            baseURL: AIProviderKind.ollama.defaultBaseURL,
            modelID: AIProviderKind.ollama.defaultModelID
        )
    }
}

/// Controls how much autonomy Ceptra AI has for editor changes and CLI agent tools.
/// Hard security guardrails (sensitive file/directory firewall, workspace jail, env scrubbing)
/// remain strictly enforced across ALL modes.
public enum AIPermissionMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case readOnly
    case askToProceed
    case fullWorkspace

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .readOnly: return "Read-Only"
        case .askToProceed: return "Ask to Proceed"
        case .fullWorkspace: return "Full Permissions"
        }
    }

    public var shortLabel: String {
        switch self {
        case .readOnly: return "Read-Only"
        case .askToProceed: return "Ask"
        case .fullWorkspace: return "Full"
        }
    }

    public var symbolName: String {
        switch self {
        case .readOnly: return "lock.fill"
        case .askToProceed: return "hand.raised.fill"
        case .fullWorkspace: return "bolt.shield.fill"
        }
    }

    public var summary: String {
        switch self {
        case .readOnly:
            return "Chat & inspect only. Editor edits and CLI workspace tools are disabled."
        case .askToProceed:
            return "Review unified diffs before applying edits. CLI agents run read-only in an isolated sandbox."
        case .fullWorkspace:
            return "1-click instant apply in active workspace and workspace-scoped tools for CLI agents."
        }
    }

    public var allowsEditorEdits: Bool {
        self != .readOnly
    }

    public var requiresDiffConfirmation: Bool {
        self == .askToProceed
    }

    public var allowsCLIWorkspaceTools: Bool {
        self == .fullWorkspace
    }
}

public struct AISettings: Codable, Equatable, Sendable {
    public var profiles: [AIProviderProfile]
    public var activeProfileID: UUID?
    public var bridgeToCodeceptAI: Bool
    public var redactSecretsInCloudContext: Bool
    public var includeWorkspaceContextByDefault: Bool
    public var permissionMode: AIPermissionMode
    public var enableGlobalAgentSkills: Bool

    public init(
        profiles: [AIProviderProfile] = [],
        activeProfileID: UUID? = nil,
        bridgeToCodeceptAI: Bool = false,
        redactSecretsInCloudContext: Bool = true,
        includeWorkspaceContextByDefault: Bool = true,
        permissionMode: AIPermissionMode = .askToProceed,
        enableGlobalAgentSkills: Bool = true
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.bridgeToCodeceptAI = bridgeToCodeceptAI
        self.redactSecretsInCloudContext = redactSecretsInCloudContext
        self.includeWorkspaceContextByDefault = includeWorkspaceContextByDefault
        self.permissionMode = permissionMode
        self.enableGlobalAgentSkills = enableGlobalAgentSkills
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.profiles = try c.decodeIfPresent([AIProviderProfile].self, forKey: .profiles) ?? []
        self.activeProfileID = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        self.bridgeToCodeceptAI = try c.decodeIfPresent(Bool.self, forKey: .bridgeToCodeceptAI) ?? false
        self.redactSecretsInCloudContext = try c.decodeIfPresent(Bool.self, forKey: .redactSecretsInCloudContext) ?? true
        self.includeWorkspaceContextByDefault = try c.decodeIfPresent(Bool.self, forKey: .includeWorkspaceContextByDefault) ?? true
        self.permissionMode = try c.decodeIfPresent(AIPermissionMode.self, forKey: .permissionMode) ?? .askToProceed
        self.enableGlobalAgentSkills = try c.decodeIfPresent(Bool.self, forKey: .enableGlobalAgentSkills) ?? true
    }

    public var activeProfile: AIProviderProfile? {
        if let activeProfileID, let match = profiles.first(where: { $0.id == activeProfileID }) {
            return match
        }
        return profiles.first
    }
}

public struct AIModelDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var contextHint: String?

    public init(id: String, displayName: String? = nil, contextHint: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
        self.contextHint = contextHint
    }
}

public enum AIChatRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
}

public struct AIImagePayload: Codable, Equatable, Hashable, Sendable {
    public let mimeType: String
    public let base64Data: String
    public let localFilePath: String?

    public init(mimeType: String, base64Data: String, localFilePath: String? = nil) {
        self.mimeType = mimeType
        self.base64Data = base64Data
        self.localFilePath = localFilePath
    }
}

public enum AIUserAttachmentKind: String, Codable, Equatable, Hashable, Sendable {
    case image
    case textFile
    case pdf
    case video

    public var contextKind: AIContextAttachmentKind {
        switch self {
        case .image: return .userImage
        case .textFile: return .userFile
        case .pdf: return .userPDF
        case .video: return .userVideo
        }
    }

    public var symbolName: String {
        switch self {
        case .image: return "photo"
        case .textFile: return "doc.text"
        case .pdf: return "doc.richtext"
        case .video: return "film"
        }
    }
}

public struct AIUserAttachment: Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: AIUserAttachmentKind
    public let displayName: String
    public let filePath: String?
    public let byteCount: Int
    public let subtitle: String
    public let textContent: String?
    public let images: [AIImagePayload]
    public let thumbnailBase64: String?
    public let wasRedacted: Bool

    public init(
        id: UUID = UUID(),
        kind: AIUserAttachmentKind,
        displayName: String,
        filePath: String? = nil,
        byteCount: Int,
        subtitle: String,
        textContent: String? = nil,
        images: [AIImagePayload] = [],
        thumbnailBase64: String? = nil,
        wasRedacted: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.filePath = filePath
        self.byteCount = byteCount
        self.subtitle = subtitle
        self.textContent = textContent
        self.images = images
        self.thumbnailBase64 = thumbnailBase64
        self.wasRedacted = wasRedacted
    }

    public var summary: AIAttachedContextSummary {
        AIAttachedContextSummary(
            id: id.uuidString,
            kind: kind.contextKind,
            label: displayName,
            byteCount: byteCount,
            wasRedacted: wasRedacted,
            thumbnailBase64: thumbnailBase64
        )
    }
}

public struct AIAttachedContextSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: AIContextAttachmentKind
    public var label: String
    public var byteCount: Int
    public var wasRedacted: Bool
    public var thumbnailBase64: String?

    public init(
        id: String,
        kind: AIContextAttachmentKind,
        label: String,
        byteCount: Int,
        wasRedacted: Bool = false,
        thumbnailBase64: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.byteCount = byteCount
        self.wasRedacted = wasRedacted
        self.thumbnailBase64 = thumbnailBase64
    }
}

public enum AIContextAttachmentKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case activeFile
    case selection
    case consoleErrors
    case replayFailure
    case codeceptAPI
    case userImage
    case userFile
    case userPDF
    case userVideo
    case skill

    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .activeFile: return "File"
        case .selection: return "Selection"
        case .consoleErrors: return "Errors"
        case .replayFailure: return "Replay"
        case .codeceptAPI: return "I.* API"
        case .userImage: return "Image"
        case .userFile: return "Attached File"
        case .userPDF: return "PDF"
        case .userVideo: return "Video"
        case .skill: return "Skill"
        }
    }

    public var symbolName: String {
        switch self {
        case .activeFile: return "doc.text"
        case .selection: return "text.cursor"
        case .consoleErrors: return "exclamationmark.triangle"
        case .replayFailure: return "clock.arrow.circlepath"
        case .codeceptAPI: return "sparkles.rectangle.stack"
        case .userImage: return "photo"
        case .userFile: return "paperclip"
        case .userPDF: return "doc.richtext"
        case .userVideo: return "film"
        case .skill: return "slash.circle.fill"
        }
    }
}

public struct AIChatMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let role: AIChatRole
    public var content: String
    public let createdAt: Date
    public var modelUsed: String?
    public var providerName: String?
    public var attachedSummaries: [AIAttachedContextSummary]
    public var images: [AIImagePayload]
    public var isError: Bool

    public init(
        id: UUID = UUID(),
        role: AIChatRole,
        content: String,
        createdAt: Date = Date(),
        modelUsed: String? = nil,
        providerName: String? = nil,
        attachedSummaries: [AIAttachedContextSummary] = [],
        images: [AIImagePayload] = [],
        isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.modelUsed = modelUsed
        self.providerName = providerName
        self.attachedSummaries = attachedSummaries
        self.images = images
        self.isError = isError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.role = try c.decode(AIChatRole.self, forKey: .role)
        self.content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.modelUsed = try c.decodeIfPresent(String.self, forKey: .modelUsed)
        self.providerName = try c.decodeIfPresent(String.self, forKey: .providerName)
        self.attachedSummaries = try c.decodeIfPresent([AIAttachedContextSummary].self, forKey: .attachedSummaries) ?? []
        self.images = try c.decodeIfPresent([AIImagePayload].self, forKey: .images) ?? []
        self.isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}

public struct AIChatSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let workspacePath: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [AIChatMessage]

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        workspacePath: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [AIChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.workspacePath = workspacePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

public struct AIChatRequest: Equatable, Sendable {
    public let systemPrompt: String
    public let messages: [AIChatMessage]
    public let temperature: Double
    public let maxTokens: Int
    public let workspaceRoot: URL?
    public let permissionMode: AIPermissionMode

    public init(
        systemPrompt: String,
        messages: [AIChatMessage],
        temperature: Double = 0.2,
        maxTokens: Int = 4096,
        workspaceRoot: URL? = nil,
        permissionMode: AIPermissionMode = .askToProceed
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.workspaceRoot = workspaceRoot
        self.permissionMode = permissionMode
    }
}

public struct AIUsageStats: Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum AIStreamDelta: Equatable, Sendable {
    case text(String)
    case usage(AIUsageStats)
    case completed(stopReason: String?)
}

public struct AIConnectionTestResult: Equatable, Sendable {
    public let ok: Bool
    public let latencyMs: Int
    public let summary: String
    public let discoveredModels: [AIModelDescriptor]

    public init(ok: Bool, latencyMs: Int, summary: String, discoveredModels: [AIModelDescriptor] = []) {
        self.ok = ok
        self.latencyMs = latencyMs
        self.summary = summary
        self.discoveredModels = discoveredModels
    }
}

public enum AIProviderError: LocalizedError, Equatable, Sendable {
    case invalidBaseURL(String)
    case insecureRemoteURL(String)
    case missingAPIKey(providerName: String)
    case missingModelID
    case cliNotFound(kind: AIProviderKind, searchedHint: String)
    case invalidCLIPath(String)
    case httpError(statusCode: Int, message: String)
    case rateLimited(retryAfterSeconds: Int?, message: String)
    case networkFailure(String)
    case redirectBlocked(String)
    case responseTooLarge(limitBytes: Int)
    case cancelled
    case decodingFailure(String)
    case cliProcessFailure(exitCode: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let reason):
            return "Invalid provider URL: \(reason)"
        case .insecureRemoteURL(let host):
            return "Refused to send credentials over plaintext HTTP to remote host '\(host)'. Use https:// or enable insecure LAN HTTP explicitly."
        case .missingAPIKey(let providerName):
            return "API key is required for \(providerName). Add it in Settings → AI Providers."
        case .missingModelID:
            return "Select or enter a model ID before sending a message."
        case .cliNotFound(let kind, let hint):
            return "\(kind.displayName) executable was not found (\(hint)). Install it or set a custom path in Settings → AI Providers."
        case .invalidCLIPath(let path):
            return "Configured CLI path is not an executable file: \(path)"
        case .httpError(let code, let message):
            if code == 401 || code == 403 {
                return "Authentication failed (HTTP \(code)). Check your API key or token permissions. \(message)".trimmingCharacters(in: .whitespaces)
            }
            if code == 404 {
                return "Endpoint or model not found (HTTP 404). Verify the model ID and base URL. \(message)".trimmingCharacters(in: .whitespaces)
            }
            return "Provider returned HTTP \(code): \(message)"
        case .rateLimited(let retry, let message):
            if let retry {
                return "Rate limited (HTTP 429). Retry in ~\(retry)s. \(message)".trimmingCharacters(in: .whitespaces)
            }
            return "Rate limited (HTTP 429). \(message)".trimmingCharacters(in: .whitespaces)
        case .networkFailure(let message):
            return message
        case .redirectBlocked(let detail):
            return "Blocked unsafe cross-origin redirect: \(detail)"
        case .responseTooLarge(let limit):
            return "AI response exceeded the \(limit / 1024) KB safety limit and was stopped."
        case .cancelled:
            return "Generation cancelled."
        case .decodingFailure(let detail):
            return "Failed to decode provider response: \(detail)"
        case .cliProcessFailure(let code, let message):
            return "CLI exited with code \(code): \(message)"
        }
    }
}
