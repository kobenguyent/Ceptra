import AppKit
import CeptraCore
import Foundation
import UniformTypeIdentifiers

enum AIQuickActionKind: String, CaseIterable, Identifiable {
    case explain
    case refactor
    case generateScenario
    case fixSelection
    case diagnoseConsoleErrors
    case debugReplayFailure

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .explain: return "Explain Selection"
        case .refactor: return "Refactor / Improve"
        case .generateScenario: return "Generate CodeceptJS Scenario"
        case .fixSelection: return "Fix / Harden Locators"
        case .diagnoseConsoleErrors: return "Diagnose Console Errors"
        case .debugReplayFailure: return "Debug Failing Replay Step"
        }
    }
}

struct AIEditorMutationRequest: Equatable {
    enum Mode: Equatable {
        case insertAtSelection
        case replaceRange(NSRange)
        case replaceDocument
    }

    let id: UUID
    let filePath: String
    let mode: Mode
    let text: String

    init(id: UUID = UUID(), filePath: String, mode: Mode, text: String) {
        self.id = id
        self.filePath = filePath
        self.mode = mode
        self.text = text
    }
}

struct AIPendingDiffPreview: Identifiable, Equatable {
    enum ApplyMode: Equatable {
        case replaceSelection(NSRange, startLine: Int, endLine: Int)
        case replaceDocument
    }

    let id = UUID()
    let filePath: String
    let relativePath: String
    let language: String
    let applyMode: ApplyMode
    let originalText: String
    let proposedText: String
    let diffResult: AIDiffResult
}

@MainActor
extension AppState {
    // MARK: - Profile & Keychain Accessors

    var activeAIProfile: AIProviderProfile? {
        settings.aiSettings.activeProfile
    }

    var aiProfiles: [AIProviderProfile] {
        settings.aiSettings.profiles
    }

    var aiPermissionMode: AIPermissionMode {
        settings.aiSettings.permissionMode
    }

    func setAIPermissionMode(_ mode: AIPermissionMode) {
        guard settings.aiSettings.permissionMode != mode else { return }
        settings.aiSettings.permissionMode = mode
        saveSettings()
        showBanner("AI Permission Mode: \(mode.displayName)")
    }

    // MARK: - Universal Slash Commands & Agent Skills (SKILL.md)

    func refreshAISkills() {
        let discovered = AISkillRegistry.discoverSkills(
            workspaceRoot: workspace?.rootURL,
            includeGlobalSkills: settings.aiSettings.enableGlobalAgentSkills
        )
        aiAvailableSkills = discovered
        if let pinned = aiPinnedSkill,
           !discovered.contains(where: { $0.id == pinned.id }) {
            aiPinnedSkill = nil
        }
    }

    func setEnableGlobalAgentSkills(_ enabled: Bool) {
        guard settings.aiSettings.enableGlobalAgentSkills != enabled else { return }
        settings.aiSettings.enableGlobalAgentSkills = enabled
        saveSettings()
        refreshAISkills()
    }

    func selectAISkill(_ descriptor: AISkillDescriptor) {
        if descriptor.isMetaBrowseCommand {
            showingAISkillsSheet = true
            return
        }
        aiPinnedSkill = descriptor
        for kind in descriptor.recommendedContextKinds {
            aiEnabledContextKinds.insert(kind)
        }
    }

    func clearAIPinnedSkill() {
        aiPinnedSkill = nil
    }

    @discardableResult
    func createAndOpenAISkill(slug: String, description: String, global: Bool) -> Bool {
        let rootDir: URL
        if global {
            rootDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ceptra/skills", isDirectory: true)
        } else if let wsRoot = workspace?.rootURL {
            rootDir = wsRoot.appendingPathComponent(".ceptra/skills", isDirectory: true)
        } else {
            showBanner("Open a workspace first to create a Project Skill (or choose Personal Global Skill).", isError: true)
            return false
        }

        do {
            let fileURL = try AISkillRegistry.createSkillTemplate(
                rawSlug: slug,
                description: description,
                inSkillsRootDirectory: rootDir
            )
            if !global {
                rescanWorkspace()
            } else {
                refreshAISkills()
            }
            openFileByURL(fileURL)
            let createdSlug = AISkillRegistry.sanitizeSlug(slug)
            showBanner("Created /\(createdSlug) skill at \(global ? "~/.ceptra/skills/\(createdSlug)/SKILL.md" : ".ceptra/skills/\(createdSlug)/SKILL.md")")
            return true
        } catch {
            showBanner(error.localizedDescription, isError: true)
            return false
        }
    }

    func hasAPIKey(for profileID: UUID) -> Bool {
        aiSecretStore.hasSecret(forProfileID: profileID)
    }

    func saveAPIKey(_ rawKey: String, for profileID: UUID) {
        do {
            try aiSecretStore.saveSecret(rawKey, forProfileID: profileID)
            aiKeychainRevision += 1
            let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            showBanner(trimmed.isEmpty ? "Removed API key from macOS Keychain" : "Saved API key securely in macOS Keychain")
        } catch {
            showBanner("Keychain error: \(error.localizedDescription)", isError: true)
        }
    }

    func deleteAPIKey(for profileID: UUID) {
        do {
            try aiSecretStore.deleteSecret(forProfileID: profileID)
            aiKeychainRevision += 1
            showBanner("Removed API key from macOS Keychain")
        } catch {
            showBanner("Keychain error: \(error.localizedDescription)", isError: true)
        }
    }

    @discardableResult
    func addAIProfile(kind: AIProviderKind) -> AIProviderProfile {
        let existingCount = settings.aiSettings.profiles.filter { $0.kind == kind }.count
        let defaultName = existingCount == 0 ? kind.displayName : "\(kind.displayName) \(existingCount + 1)"
        var profile = AIProviderProfile(name: defaultName, kind: kind)
        if kind == .ollama {
            let installedNames = ollamaStatus.installedModels.map(\.name)
            if !installedNames.isEmpty {
                profile.availableModels = installedNames
                profile.modelID = installedNames[0]
            }
        }
        settings.aiSettings.profiles.append(profile)
        settings.aiSettings.activeProfileID = profile.id
        saveSettings()
        return profile
    }

    func updateAIProfile(_ updated: AIProviderProfile) {
        guard let idx = settings.aiSettings.profiles.firstIndex(where: { $0.id == updated.id }) else { return }
        settings.aiSettings.profiles[idx] = updated
        saveSettings()
    }

    func deleteAIProfile(id: UUID) {
        try? aiSecretStore.deleteSecret(forProfileID: id)
        aiKeychainRevision += 1
        settings.aiSettings.profiles.removeAll { $0.id == id }
        if settings.aiSettings.activeProfileID == id {
            settings.aiSettings.activeProfileID = settings.aiSettings.profiles.first?.id
        }
        aiConnectionStatusByProfileID.removeValue(forKey: id)
        saveSettings()
    }

    func selectAIProfile(id: UUID) {
        guard settings.aiSettings.profiles.contains(where: { $0.id == id }) else { return }
        settings.aiSettings.activeProfileID = id
        saveSettings()
    }

    func selectAIModel(_ modelID: String, for profileID: UUID) {
        guard let idx = settings.aiSettings.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.aiSettings.profiles[idx].modelID = trimmed
        if !settings.aiSettings.profiles[idx].availableModels.contains(trimmed) {
            settings.aiSettings.profiles[idx].availableModels.insert(trimmed, at: 0)
        }
        saveSettings()
    }

    func ensureDefaultLocalOllamaIfEmpty() {
        guard settings.aiSettings.profiles.isEmpty else { return }
        let ollama = AIProviderProfile(name: AIProviderKind.ollama.displayName, kind: .ollama)
        settings.aiSettings.profiles = [ollama]
        settings.aiSettings.activeProfileID = ollama.id
        saveSettings()
        Task { [weak self] in
            await self?.refreshOllamaStatus(for: ollama, force: true)
        }
    }

    func quickConnectLocalOllama() {
        let profile: AIProviderProfile
        if let existing = settings.aiSettings.profiles.first(where: { $0.kind == .ollama }) {
            profile = existing
            selectAIProfile(id: existing.id)
        } else {
            profile = addAIProfile(kind: .ollama)
        }
        Task {
            await refreshOllamaStatus(for: profile)
            if case .running(let models) = ollamaStatus, !models.isEmpty {
                showBanner("Connected to Local Ollama (\(models.count) model\(models.count == 1 ? "" : "s") ready)")
            } else {
                openAIProviderSettings(selecting: profile.id, addGallery: false)
            }
        }
    }

    func openAIProviderSettings(selecting profileID: UUID? = nil, addGallery: Bool = false) {
        aiSettingsInitialProfileID = profileID
        aiSettingsStartInAddGallery = addGallery
        showingAIProviderSettingsSheet = true
    }

    func cancelAllAIBackgroundTasks() {
        stopAIGeneration()
        cancelOllamaModelPull()
        cancelOllamaInstall()
    }

    func refreshDetectedAICLIs() {
        detectedAICLIs = AICLIProviderClient.detectInstalledCLIs()
    }

    // MARK: - Guided Local Ollama Setup & Model Management

    func refreshOllamaStatus(for explicitProfile: AIProviderProfile? = nil, force: Bool = false) async {
        guard !isCheckingOllama else { return }
        if !force, ollamaStatus != .unknown, let last = lastOllamaProbeAt, Date().timeIntervalSince(last) < 3.0 {
            return
        }

        let profile = explicitProfile
            ?? (activeAIProfile?.kind == .ollama ? activeAIProfile : nil)
            ?? settings.aiSettings.profiles.first(where: { $0.kind == .ollama })
        let baseURL = profile?.baseURL ?? AIProviderKind.ollama.defaultBaseURL
        let allowLAN = profile?.allowInsecureLocalHTTP ?? false
        let apiKey = profile.flatMap { aiSecretStore.loadSecret(forProfileID: $0.id) }

        isCheckingOllama = true
        defer {
            isCheckingOllama = false
            lastOllamaProbeAt = Date()
        }

        let status = await ollamaManager.probeStatus(
            baseURL: baseURL,
            allowInsecureLocalHTTP: allowLAN,
            apiKey: apiKey
        )
        if ollamaStatus != status {
            ollamaStatus = status
        }

        // Sync real installed models to matching Ollama profile(s) — zero ghost models
        let installedNames = status.installedModels.map(\.name)
        var didMutateSettings = false
        for idx in settings.aiSettings.profiles.indices where settings.aiSettings.profiles[idx].kind == .ollama {
            let p = settings.aiSettings.profiles[idx]
            let sameEndpoint = p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sameEndpoint || profile == nil else { continue }

            switch status {
            case .running:
                if settings.aiSettings.profiles[idx].availableModels != installedNames {
                    settings.aiSettings.profiles[idx].availableModels = installedNames
                    didMutateSettings = true
                }
                if !installedNames.contains(settings.aiSettings.profiles[idx].modelID),
                   let first = installedNames.first {
                    settings.aiSettings.profiles[idx].modelID = first
                    didMutateSettings = true
                }
                let nextResult = AIConnectionTestResult(
                    ok: true,
                    latencyMs: 0,
                    summary: "Ollama running · \(installedNames.count) installed model\(installedNames.count == 1 ? "" : "s")"
                )
                if aiConnectionStatusByProfileID[p.id] != nextResult {
                    aiConnectionStatusByProfileID[p.id] = nextResult
                }
            case .runningNoModels:
                if !settings.aiSettings.profiles[idx].availableModels.isEmpty {
                    settings.aiSettings.profiles[idx].availableModels = []
                    didMutateSettings = true
                }
                if !settings.aiSettings.profiles[idx].modelID.isEmpty {
                    settings.aiSettings.profiles[idx].modelID = ""
                    didMutateSettings = true
                }
                if aiConnectionStatusByProfileID[p.id] != nil {
                    aiConnectionStatusByProfileID.removeValue(forKey: p.id)
                }
            case .notInstalled, .installedNotRunning, .remoteUnreachable, .unknown:
                // Never leave stale ghost models when Ollama is not reachable
                if !settings.aiSettings.profiles[idx].availableModels.isEmpty {
                    settings.aiSettings.profiles[idx].availableModels = []
                    didMutateSettings = true
                }
                if aiConnectionStatusByProfileID[p.id] != nil {
                    aiConnectionStatusByProfileID.removeValue(forKey: p.id)
                }
            }
        }
        if didMutateSettings {
            saveSettings()
        }
    }

    func openOllamaDownloadPage() {
        NSWorkspace.shared.open(OllamaManager.downloadPageURL)
    }

    func installOllamaViaHomebrew() {
        guard case .notInstalled(let brewPathOpt) = ollamaStatus,
              let brewPath = brewPathOpt else {
            openOllamaDownloadPage()
            return
        }
        cancelOllamaInstall()
        isInstallingOllamaApp = true
        ollamaInstallLogLine = "Starting Homebrew install (brew install --cask ollama)…"
        ollamaPullError = nil

        let manager = ollamaManager
        ollamaInstallTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in manager.installViaHomebrew(brewPath: brewPath) {
                    if Task.isCancelled { return }
                    self.ollamaInstallLogLine = line
                }
                self.isInstallingOllamaApp = false
                self.ollamaInstallLogLine = ""
                self.ollamaInstallTask = nil
                self.showBanner("Ollama installed via Homebrew — starting local server…")
                await self.startLocalOllama()
            } catch let err as OllamaManagerError where err == .cancelled {
                self.isInstallingOllamaApp = false
                self.ollamaInstallLogLine = ""
                self.ollamaInstallTask = nil
            } catch {
                self.isInstallingOllamaApp = false
                self.ollamaInstallLogLine = ""
                self.ollamaInstallTask = nil
                self.ollamaPullError = error.localizedDescription
                self.showBanner(error.localizedDescription, isError: true)
            }
        }
    }

    func cancelOllamaInstall() {
        ollamaInstallTask?.cancel()
        ollamaInstallTask = nil
        ollamaManager.cancelAllProcesses()
        if isInstallingOllamaApp {
            isInstallingOllamaApp = false
            ollamaInstallLogLine = ""
        }
    }

    func startLocalOllama() async {
        let profile = (activeAIProfile?.kind == .ollama ? activeAIProfile : nil)
            ?? settings.aiSettings.profiles.first(where: { $0.kind == .ollama })
        let baseURL = profile?.baseURL ?? AIProviderKind.ollama.defaultBaseURL

        isStartingOllama = true
        ollamaPullError = nil
        defer { isStartingOllama = false }

        var appURL: URL? = nil
        var cliURL: URL? = nil
        if case .installedNotRunning(let a, let c) = ollamaStatus {
            appURL = a
            cliURL = c
        }

        do {
            let status = try await ollamaManager.startLocalServer(
                baseURL: baseURL,
                appURL: appURL,
                cliURL: cliURL
            )
            ollamaStatus = status
            await refreshOllamaStatus(for: profile, force: true)
            showBanner("Ollama server is running on \(baseURL)")
        } catch {
            ollamaPullError = error.localizedDescription
            showBanner(error.localizedDescription, isError: true)
            await refreshOllamaStatus(for: profile, force: true)
        }
    }

    func pullOllamaModel(_ rawModelName: String, for explicitProfile: AIProviderProfile? = nil) {
        let profile = explicitProfile
            ?? (activeAIProfile?.kind == .ollama ? activeAIProfile : nil)
            ?? settings.aiSettings.profiles.first(where: { $0.kind == .ollama })
        let baseURL = profile?.baseURL ?? AIProviderKind.ollama.defaultBaseURL
        let allowLAN = profile?.allowInsecureLocalHTTP ?? false
        let apiKey = profile.flatMap { aiSecretStore.loadSecret(forProfileID: $0.id) }

        let validName: String
        do {
            validName = try OllamaManager.validateModelName(rawModelName)
        } catch {
            ollamaPullError = error.localizedDescription
            showBanner(error.localizedDescription, isError: true)
            return
        }

        cancelOllamaModelPull()
        ollamaPullError = nil
        ollamaPullProgress = OllamaPullProgress(modelName: validName, status: "connecting…")

        let manager = ollamaManager
        let targetProfileID = profile?.id
        ollamaPullTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = manager.pullModel(
                    name: validName,
                    baseURL: baseURL,
                    allowInsecureLocalHTTP: allowLAN,
                    apiKey: apiKey
                )
                for try await progress in stream {
                    if Task.isCancelled { return }
                    self.ollamaPullProgress = progress
                }
                self.ollamaPullProgress = nil
                self.ollamaPullTask = nil
                await self.refreshOllamaStatus(for: profile, force: true)
                if let pid = targetProfileID {
                    self.selectAIModel(validName, for: pid)
                }
                self.showBanner("Installed local model '\(validName)' and set as active")
            } catch let err as OllamaManagerError where err == .cancelled {
                self.ollamaPullProgress = nil
                self.ollamaPullTask = nil
            } catch {
                self.ollamaPullProgress = nil
                self.ollamaPullTask = nil
                self.ollamaPullError = error.localizedDescription
                self.showBanner(error.localizedDescription, isError: true)
            }
        }
    }

    func cancelOllamaModelPull() {
        ollamaPullTask?.cancel()
        ollamaPullTask = nil
        if ollamaPullProgress != nil {
            ollamaPullProgress = nil
        }
    }

    func deleteOllamaModel(_ modelName: String, for explicitProfile: AIProviderProfile? = nil) async {
        let profile = explicitProfile
            ?? (activeAIProfile?.kind == .ollama ? activeAIProfile : nil)
            ?? settings.aiSettings.profiles.first(where: { $0.kind == .ollama })
        let baseURL = profile?.baseURL ?? AIProviderKind.ollama.defaultBaseURL
        let allowLAN = profile?.allowInsecureLocalHTTP ?? false
        let apiKey = profile.flatMap { aiSecretStore.loadSecret(forProfileID: $0.id) }

        do {
            try await ollamaManager.deleteModel(
                name: modelName,
                baseURL: baseURL,
                allowInsecureLocalHTTP: allowLAN,
                apiKey: apiKey
            )
            await refreshOllamaStatus(for: profile, force: true)
            showBanner("Removed local Ollama model '\(modelName)'")
        } catch {
            ollamaPullError = error.localizedDescription
            showBanner(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Unified Guided Setup Helpers (Cloud APIs, OpenAI-Compatible Presets, CLIs)

    func saveAPIKeyAndTest(_ rawKey: String, for profileID: UUID) async {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            saveAPIKey(trimmed, for: profileID)
        }
        await testAIProviderConnection(profileID: profileID)
    }

    func applyOpenAICompatiblePreset(_ preset: OpenAICompatiblePreset, to profileID: UUID) {
        guard let idx = settings.aiSettings.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        settings.aiSettings.profiles[idx].baseURL = preset.baseURL
        settings.aiSettings.profiles[idx].name = preset.id == "custom" ? "OpenAI-Compatible" : preset.name
        settings.aiSettings.profiles[idx].availableModels = preset.defaultModels
        if let first = preset.defaultModels.first {
            settings.aiSettings.profiles[idx].modelID = first
        }
        aiConnectionStatusByProfileID.removeValue(forKey: profileID)
        saveSettings()
        showBanner("Applied \(preset.name) preset (\(preset.baseURL))")
    }

    func openTerminalForCLISetup(command: String, title: String) {
        let workDir = workspace?.rootURL ?? FileManager.default.homeDirectoryForCurrentUser
        let toolchain = resolvedToolchain ?? NodeToolchainResolver.resolve(
            workspaceRoot: workDir,
            runtime: settings.jsRuntime,
            customBunPath: settings.customBunPath
        )
        let built = BuiltCommand(
            executablePath: "/bin/zsh",
            arguments: ["-c", command],
            workingDirectory: workDir,
            environment: ProcessInfo.processInfo.environment,
            environmentOverrides: [:],
            displayCommand: command
        )
        do {
            let terminalName = try SystemTerminalLauncher.launch(
                command: built,
                runtime: settings.jsRuntime,
                title: title,
                toolchain: toolchain,
                preferredAppPath: settings.customTerminalAppPath,
                keepShellOpen: true
            )
            showBanner("Opened \(terminalName) for \(title)")
        } catch {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            showBanner("Copied '\(command)' to clipboard (\(error.localizedDescription))", isError: true)
        }
    }

    func testAIProviderConnection(profileID: UUID) async {
        guard let profile = settings.aiSettings.profiles.first(where: { $0.id == profileID }) else { return }
        aiTestingProfileID = profileID
        aiLastError = nil
        let apiKey = aiSecretStore.loadSecret(forProfileID: profileID)
        defer {
            if aiTestingProfileID == profileID {
                aiTestingProfileID = nil
            }
        }

        do {
            let result = try await aiRouter.testConnection(profile: profile, apiKey: apiKey)
            aiConnectionStatusByProfileID[profileID] = result
            if !result.discoveredModels.isEmpty,
               let idx = settings.aiSettings.profiles.firstIndex(where: { $0.id == profileID }) {
                let ids = result.discoveredModels.map(\.id)
                settings.aiSettings.profiles[idx].availableModels = ids
                if !ids.contains(settings.aiSettings.profiles[idx].modelID), let first = ids.first {
                    settings.aiSettings.profiles[idx].modelID = first
                }
                saveSettings()
            }
            showBanner(result.summary)
        } catch {
            let msg = error.localizedDescription
            aiConnectionStatusByProfileID[profileID] = AIConnectionTestResult(ok: false, latencyMs: 0, summary: msg)
            showBanner(msg, isError: true)
        }
    }

    func fetchModelsForAIProfile(profileID: UUID) async {
        guard let profile = settings.aiSettings.profiles.first(where: { $0.id == profileID }) else { return }
        aiFetchingModelsProfileID = profileID
        let apiKey = aiSecretStore.loadSecret(forProfileID: profileID)
        defer {
            if aiFetchingModelsProfileID == profileID {
                aiFetchingModelsProfileID = nil
            }
        }

        do {
            let models = try await aiRouter.listModels(profile: profile, apiKey: apiKey)
            let ids = models.map(\.id)
            if !ids.isEmpty, let idx = settings.aiSettings.profiles.firstIndex(where: { $0.id == profileID }) {
                settings.aiSettings.profiles[idx].availableModels = ids
                if !ids.contains(settings.aiSettings.profiles[idx].modelID), let first = ids.first {
                    settings.aiSettings.profiles[idx].modelID = first
                }
                saveSettings()
            }
            showBanner("Fetched \(ids.count) model\(ids.count == 1 ? "" : "s") for \(profile.name)")
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Conversation Lifecycle & Persistence

    func loadAISessionsForWorkspace(rootPath: String) {
        stopAIGeneration()
        aiSessions = aiConversationStore.loadSessions(forWorkspacePath: rootPath)
        if let first = aiSessions.first {
            activeAISessionID = first.id
        } else {
            let fresh = AIChatSession(workspacePath: rootPath)
            aiSessions = [fresh]
            activeAISessionID = fresh.id
        }
        aiLastError = nil
        refreshDetectedAICLIs()
    }

    var activeAISession: AIChatSession? {
        if let activeAISessionID, let match = aiSessions.first(where: { $0.id == activeAISessionID }) {
            return match
        }
        return aiSessions.first
    }

    func startNewAIChat() {
        stopAIGeneration()
        let wsPath = workspace?.rootURL.path ?? "global"
        // Reuse an existing empty draft session instead of accumulating duplicate "New Chat (0 msgs)" rows
        if let existingEmpty = aiSessions.first(where: { $0.messages.isEmpty }) {
            activeAISessionID = existingEmpty.id
            aiLastError = nil
            return
        }
        let fresh = AIChatSession(workspacePath: wsPath)
        aiSessions.insert(fresh, at: 0)
        activeAISessionID = fresh.id
        aiLastError = nil
    }

    func selectAISession(id: UUID) {
        stopAIGeneration()
        activeAISessionID = id
        // Prune unused empty drafts when switching to a saved conversation
        aiSessions.removeAll { $0.id != id && $0.messages.isEmpty }
        aiLastError = nil
    }

    func deleteAISession(id: UUID) {
        let wasActive = activeAISessionID == id || activeAISession?.id == id
        if wasActive {
            stopAIGeneration()
        }
        aiSessions.removeAll { $0.id == id }
        if aiSessions.isEmpty {
            let wsPath = workspace?.rootURL.path ?? "global"
            let fresh = AIChatSession(workspacePath: wsPath)
            aiSessions = [fresh]
            activeAISessionID = fresh.id
        } else if wasActive {
            activeAISessionID = aiSessions.first?.id
        }
        aiLastError = nil
        persistAISessions()
    }

    func deleteAllAISessions() {
        stopAIGeneration()
        let wsPath = workspace?.rootURL.path ?? "global"
        aiConversationStore.clearSessions(forWorkspacePath: wsPath)
        let fresh = AIChatSession(workspacePath: wsPath)
        aiSessions = [fresh]
        activeAISessionID = fresh.id
        aiLastError = nil
        showBanner("Cleared all AI conversations")
    }

    var savedAISessions: [AIChatSession] {
        aiSessions.filter { !$0.messages.isEmpty }
    }

    func clearActiveAIChat() {
        stopAIGeneration()
        guard let idx = activeAISessionIndex else {
            startNewAIChat()
            return
        }
        aiSessions[idx].messages = []
        aiSessions[idx].title = "New Chat"
        aiSessions[idx].updatedAt = Date()
        aiLastError = nil
        persistAISessions()
    }

    private var activeAISessionIndex: Int? {
        if let id = activeAISessionID {
            return aiSessions.firstIndex(where: { $0.id == id })
        }
        return aiSessions.isEmpty ? nil : 0
    }

    private func persistAISessions() {
        let wsPath = workspace?.rootURL.path ?? "global"
        let knownSecrets: [String] = settings.aiSettings.profiles.compactMap {
            aiSecretStore.loadSecret(forProfileID: $0.id)
        }
        aiConversationStore.saveSessions(
            aiSessions,
            forWorkspacePath: wsPath,
            explicitSecretsToStrip: knownSecrets
        )
    }

    // MARK: - Context Gathering

    func buildCurrentAIContextInput(overrideReplayStep: ExecutedStepRecord? = nil) -> AIContextInput {
        let errorLines = consoleLogs
            .filter { $0.isError || $0.text.contains("✖") || $0.text.contains("FAIL") || $0.text.contains("Error:") }
            .map(\.text)

        let failingStep: ExecutedStepRecord? = overrideReplayStep ?? latestFailingReplayStep

        let customStepNames = completionIndex.customActorMethods.map { item in
            item.signature.isEmpty ? item.label : "\(item.label)\(item.signature)"
        }
        let pageNames = completionIndex.memberMethodsByAlias.keys.sorted().map { alias -> String in
            let methods = (completionIndex.memberMethodsByAlias[alias] ?? []).prefix(8).map(\.label)
            return methods.isEmpty ? alias : "\(alias)(\(methods.joined(separator: ", ")))"
        }

        return AIContextInput(
            activeFilePath: activeTab?.filePath,
            activeFileRelativePath: activeTab?.relativePath,
            activeFileLanguage: activeTab?.language,
            activeFileContent: activeTab?.content,
            cursorLine: cursorLine,
            selectedText: editorSelectedText.isEmpty ? nil : editorSelectedText,
            selectedLineRange: editorSelectedLineRange,
            consoleErrorLines: errorLines,
            failingReplayStep: failingStep,
            helperDisplayName: activeHelperDisplayName,
            customStepNames: customStepNames,
            pageObjectNames: pageNames
        )
    }

    var latestFailingReplayStep: ExecutedStepRecord? {
        if let step = pinnedAIReplayStep { return step }
        if let bundle = activeReplayTraceBundle {
            for sc in bundle.scenarios {
                if let failed = sc.steps.first(where: { $0.status == .failed || $0.errorMessage != nil }) {
                    return failed
                }
            }
        }
        if let report = selectedReport {
            for sc in report.scenarios {
                if let failed = sc.steps.first(where: { $0.status == .failed || $0.errorMessage != nil }) {
                    return failed
                }
            }
        }
        return liveReplaySteps.first(where: { $0.status == .failed || $0.errorMessage != nil })
    }

    var availableAIContextAttachments: [AIContextAttachment] {
        let redact = settings.aiSettings.redactSecretsInCloudContext && (activeAIProfile?.sendsDataToCloud ?? true)
        return AIContextAssembler.availableAttachments(
            from: buildCurrentAIContextInput(),
            redactSecrets: redact
        )
    }

    func toggleAIContextKind(_ kind: AIContextAttachmentKind) {
        if aiEnabledContextKinds.contains(kind) {
            aiEnabledContextKinds.remove(kind)
        } else {
            aiEnabledContextKinds.insert(kind)
        }
    }

    // MARK: - User Media & File Attachments

    var aiPendingVisionFrameCount: Int {
        aiPendingAttachments.reduce(0) { $0 + $1.images.count }
    }

    var latestWorkspaceScreenshotURL: URL? {
        let fm = FileManager.default
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp"]

        if let artifact = artifacts
            .filter({ ($0.kind == .screenshot || imageExts.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())) && fm.fileExists(atPath: $0.path) })
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
            .first {
            return artifact.url
        }

        guard let root = workspace?.rootURL else { return nil }
        let candidateDirs = [
            root.appendingPathComponent("output", isDirectory: true),
            root.appendingPathComponent("artifacts", isDirectory: true)
        ]
        var newest: (url: URL, date: Date)? = nil
        for dir in candidateDirs where fm.fileExists(atPath: dir.path) {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in items {
                guard imageExts.contains(url.pathExtension.lowercased()),
                      let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      vals.isRegularFile == true else { continue }
                let mod = vals.contentModificationDate ?? .distantPast
                if newest == nil || mod > newest!.date {
                    newest = (url, mod)
                }
            }
        }
        return newest?.url
    }

    var quickPickWorkspaceFileURLs: [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        func appendIfValid(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path),
                  FileManager.default.fileExists(atPath: path),
                  !AIMediaAttachmentProcessor.isBlockedSecretFile(url: url) else { return }
            seen.insert(path)
            result.append(url)
        }

        for tab in openTabs {
            appendIfValid(URL(fileURLWithPath: tab.filePath))
        }
        if let ws = workspace {
            for file in ws.configAndHelperFiles + ws.supportFiles + ws.testFiles {
                if result.count >= 10 { break }
                appendIfValid(URL(fileURLWithPath: file.path))
            }
        }
        return Array(result.prefix(10))
    }

    func presentAIFileAttachmentPanel() {
        let panel = NSOpenPanel()
        panel.title = "Attach Files, Images, PDFs, or Videos"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.directoryURL = workspace?.rootURL

        if panel.runModal() == .OK {
            addAIAttachments(from: panel.urls)
        }
    }

    func addAIAttachments(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        let shouldRedact = settings.aiSettings.redactSecretsInCloudContext && (activeAIProfile?.sendsDataToCloud ?? true)
        let explicitSecrets: [String] = activeAIProfile
            .flatMap { aiSecretStore.loadSecret(forProfileID: $0.id) }
            .map { [$0] } ?? []

        var errors: [String] = []
        var addedCount = 0

        for url in urls {
            let standardized = url.standardizedFileURL
            if aiPendingAttachments.contains(where: { $0.filePath == standardized.path }) {
                continue
            }
            if aiPendingAttachments.count >= AIMediaAttachmentProcessor.maxAttachmentsPerMessage {
                errors.append(AIMediaAttachmentError.attachmentLimitReached(maxCount: AIMediaAttachmentProcessor.maxAttachmentsPerMessage).localizedDescription)
                break
            }
            do {
                var item = try AIMediaAttachmentProcessor.processFile(
                    at: standardized,
                    workspaceRoot: workspace?.rootURL,
                    redactSecrets: shouldRedact,
                    explicitSecrets: explicitSecrets
                )
                if !item.images.isEmpty {
                    let remainingFrames = max(0, AIMediaAttachmentProcessor.maxVisionFramesPerMessage - aiPendingVisionFrameCount)
                    if remainingFrames == 0 {
                        errors.append("Vision frame limit (\(AIMediaAttachmentProcessor.maxVisionFramesPerMessage)) reached. Remove an image or video before attaching '\(item.displayName)'.")
                        continue
                    }
                    if item.images.count > remainingFrames {
                        item = AIUserAttachment(
                            id: item.id,
                            kind: item.kind,
                            displayName: item.displayName,
                            filePath: item.filePath,
                            byteCount: item.byteCount,
                            subtitle: item.subtitle,
                            textContent: item.textContent,
                            images: Array(item.images.prefix(remainingFrames)),
                            thumbnailBase64: item.thumbnailBase64,
                            wasRedacted: item.wasRedacted
                        )
                    }
                }
                aiPendingAttachments.append(item)
                addedCount += 1
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        if addedCount > 0 && errors.isEmpty {
            aiLastError = nil
        }
        if let firstError = errors.first {
            aiLastError = firstError
            showBanner(firstError, isError: true)
        }
    }

    func addAIClipboardImageAttachment(_ image: NSImage, displayName: String? = nil) {
        if aiPendingAttachments.count >= AIMediaAttachmentProcessor.maxAttachmentsPerMessage {
            let msg = AIMediaAttachmentError.attachmentLimitReached(maxCount: AIMediaAttachmentProcessor.maxAttachmentsPerMessage).localizedDescription
            aiLastError = msg
            showBanner(msg, isError: true)
            return
        }
        if aiPendingVisionFrameCount >= AIMediaAttachmentProcessor.maxVisionFramesPerMessage {
            let msg = "Vision frame limit (\(AIMediaAttachmentProcessor.maxVisionFramesPerMessage)) reached. Remove an image or video first."
            aiLastError = msg
            showBanner(msg, isError: true)
            return
        }

        let imageData: Data?
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            imageData = png
        } else {
            imageData = image.tiffRepresentation
        }

        guard let data = imageData else {
            let msg = "Could not read image data from clipboard."
            aiLastError = msg
            showBanner(msg, isError: true)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        let resolvedName = displayName ?? "Clipboard-\(formatter.string(from: Date())).png"

        do {
            let needsLocalTempFile = activeAIProfile?.kind == .codexCLI
            let attachment = try AIMediaAttachmentProcessor.processImageData(
                data,
                displayName: resolvedName,
                filePath: nil,
                persistTempFileIfNeeded: needsLocalTempFile
            )
            aiPendingAttachments.append(attachment)
            aiLastError = nil
        } catch {
            aiLastError = error.localizedDescription
            showBanner(error.localizedDescription, isError: true)
        }
    }

    @discardableResult
    func pasteFromClipboardIntoAIAttachments() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            addAIAttachments(from: urls)
            return true
        }
        if let image = NSImage(pasteboard: pb) {
            addAIClipboardImageAttachment(image)
            return true
        }
        showBanner("Clipboard does not contain an image or file.", isError: true)
        return false
    }

    func attachLatestWorkspaceScreenshot() {
        guard let url = latestWorkspaceScreenshotURL else {
            showBanner("No screenshots found in output/ or artifacts/ yet.", isError: true)
            return
        }
        addAIAttachments(from: [url])
    }

    func removeAIPendingAttachment(id: UUID) {
        aiPendingAttachments.removeAll { $0.id == id }
    }

    func clearAIPendingAttachments() {
        aiPendingAttachments.removeAll()
        AIMediaAttachmentProcessor.cleanupTemporaryMediaFiles()
    }

    // MARK: - Streaming Chat Dispatch

    func sendAIMessage(_ explicitPrompt: String? = nil) {
        let pendingAttachments = explicitPrompt == nil ? aiPendingAttachments : []
        let pinnedSkill = explicitPrompt == nil ? aiPinnedSkill : nil
        let trimmedInput = (explicitPrompt ?? aiComposerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty || !pendingAttachments.isEmpty || pinnedSkill != nil else { return }

        if aiAvailableSkills.isEmpty {
            refreshAISkills()
        }

        // Resolve slash command (inline `/slug [args]`) or pinned skill chip
        let parsedSlash = AISkillRegistry.parseSlashCommand(in: trimmedInput, available: aiAvailableSkills)
        if let parsedSlash, parsedSlash.isMetaBrowse {
            if explicitPrompt == nil {
                aiComposerText = ""
            }
            showingAISkillsSheet = true
            return
        }

        let invokedDescriptor: AISkillDescriptor? = parsedSlash?.descriptor ?? pinnedSkill
        let invokedArguments: String = {
            if let parsedSlash { return parsedSlash.arguments }
            return trimmedInput
        }()

        let rawPrompt: String = {
            if let descriptor = invokedDescriptor {
                if !invokedArguments.isEmpty {
                    return "\(descriptor.slashCommand) \(invokedArguments)"
                }
                return descriptor.slashCommand
            }
            if !trimmedInput.isEmpty {
                return trimmedInput
            }
            return "Analyze the attached \(pendingAttachments.count == 1 ? "file/media" : "files and media") in the context of this CodeceptJS project."
        }()

        let modelUserMessage: String = {
            if let descriptor = invokedDescriptor {
                if !invokedArguments.isEmpty {
                    return "Run skill `\(descriptor.slashCommand)` (`\(descriptor.title)`): \(invokedArguments)"
                }
                return "Run skill `\(descriptor.slashCommand)` (`\(descriptor.title)`) on the attached workspace context."
            }
            return rawPrompt
        }()

        guard let profile = activeAIProfile else {
            aiLastError = "No AI provider configured yet. Connect Local Ollama or add a Cloud/CLI provider in Settings → AI Providers."
            return
        }

        let apiKey = aiSecretStore.loadSecret(forProfileID: profile.id)
        if profile.kind.requiresAPIKey && (apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            aiLastError = AIProviderError.missingAPIKey(providerName: profile.name).localizedDescription
            return
        }
        if !profile.kind.isCLI && profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if profile.kind == .ollama {
                aiLastError = "No local Ollama model is selected yet. Open Configure AI Providers to start Ollama or install a coding model."
            } else {
                aiLastError = AIProviderError.missingModelID.localizedDescription
            }
            return
        }

        let shouldRedact = settings.aiSettings.redactSecretsInCloudContext && profile.sendsDataToCloud
        let explicitSecrets = apiKey.map { [$0] } ?? []
        let contextInput = buildCurrentAIContextInput()

        var resolvedSkillInvocation: AISkillInvocation? = nil
        if let descriptor = invokedDescriptor {
            do {
                resolvedSkillInvocation = try AISkillRegistry.loadAndResolveSkill(
                    descriptor,
                    arguments: invokedArguments,
                    context: contextInput,
                    workspaceRoot: workspace?.rootURL,
                    redactSecrets: shouldRedact,
                    explicitSecrets: explicitSecrets
                )
            } catch {
                aiLastError = error.localizedDescription
                showBanner(error.localizedDescription, isError: true)
                return
            }
        }

        stopAIGeneration()
        if explicitPrompt == nil {
            aiComposerText = ""
            aiPendingAttachments = []
            aiPinnedSkill = nil
        }
        aiLastError = nil

        if activeAISessionIndex == nil {
            startNewAIChat()
        }
        guard let sessionIdx = activeAISessionIndex else { return }

        var effectiveContextKinds = aiEnabledContextKinds
        if let descriptor = invokedDescriptor {
            for kind in descriptor.recommendedContextKinds {
                effectiveContextKinds.insert(kind)
            }
        }

        let assembled = AIContextAssembler.assemblePrompt(
            userMessage: modelUserMessage,
            input: contextInput,
            enabledKinds: effectiveContextKinds,
            redactSecrets: shouldRedact,
            explicitSecrets: explicitSecrets,
            activeSkill: resolvedSkillInvocation
        )

        var attachmentTextBlocks: [String] = []
        var wireImages: [AIImagePayload] = []
        for item in pendingAttachments {
            if let textContent = item.textContent, !textContent.isEmpty {
                attachmentTextBlocks.append(textContent)
            }
            if !item.images.isEmpty {
                let remaining = max(0, AIMediaAttachmentProcessor.maxVisionFramesPerMessage - wireImages.count)
                if remaining > 0 {
                    wireImages.append(contentsOf: item.images.prefix(remaining))
                }
            }
        }

        let finalAugmentedUserMessage: String
        if attachmentTextBlocks.isEmpty {
            finalAugmentedUserMessage = assembled.augmentedUserMessage
        } else {
            finalAugmentedUserMessage = """
            \(assembled.augmentedUserMessage)

            ### User Attached Files & Media
            \(attachmentTextBlocks.joined(separator: "\n\n"))
            """
        }

        let allAttachedSummaries = assembled.attachments.map(\.summary) + pendingAttachments.map(\.summary)

        let displayUserMessage = AIChatMessage(
            role: .user,
            content: rawPrompt,
            attachedSummaries: allAttachedSummaries
        )
        let assistantPlaceholder = AIChatMessage(
            role: .assistant,
            content: "",
            modelUsed: profile.modelID,
            providerName: profile.shortDisplayTitle
        )

        if aiSessions[sessionIdx].messages.isEmpty {
            let trimmedTitle = String(rawPrompt.prefix(44))
            aiSessions[sessionIdx].title = trimmedTitle
        }

        // Build wire messages (previous turns + current augmented user message with media)
        var wireMessages = aiSessions[sessionIdx].messages.filter { !$0.isError }
        wireMessages.append(
            AIChatMessage(
                role: .user,
                content: finalAugmentedUserMessage,
                images: wireImages
            )
        )

        aiSessions[sessionIdx].messages.append(displayUserMessage)
        aiSessions[sessionIdx].messages.append(assistantPlaceholder)
        aiSessions[sessionIdx].updatedAt = Date()
        let assistantMessageID = assistantPlaceholder.id
        let targetSessionID = aiSessions[sessionIdx].id
        persistAISessions()

        let streamID = UUID()
        aiActiveStreamID = streamID
        isAIStreaming = true

        let chatRequest = AIChatRequest(
            systemPrompt: assembled.systemPrompt,
            messages: wireMessages,
            temperature: profile.temperature,
            maxTokens: profile.maxTokens,
            workspaceRoot: workspace?.rootURL,
            permissionMode: settings.aiSettings.permissionMode
        )

        let router = aiRouter
        aiStreamTask = Task { [weak self] in
            guard let self else { return }
            defer {
                AIMediaAttachmentProcessor.cleanupTemporaryMediaFiles()
            }
            do {
                let stream = router.streamChat(request: chatRequest, profile: profile, apiKey: apiKey)
                for try await delta in stream {
                    guard self.aiActiveStreamID == streamID else { return }
                    switch delta {
                    case .text(let chunk):
                        self.appendAssistantChunk(chunk, sessionID: targetSessionID, messageID: assistantMessageID)
                    case .usage, .completed:
                        break
                    }
                }
                guard self.aiActiveStreamID == streamID else { return }
                self.isAIStreaming = false
                self.aiStreamTask = nil
                self.persistAISessions()
            } catch let err as AIProviderError where err == .cancelled {
                guard self.aiActiveStreamID == streamID else { return }
                self.isAIStreaming = false
                self.aiStreamTask = nil
                self.persistAISessions()
            } catch {
                guard self.aiActiveStreamID == streamID else { return }
                self.isAIStreaming = false
                self.aiStreamTask = nil
                let msg = AISecretRedactor.redact(error.localizedDescription, explicitSecrets: explicitSecrets).text
                self.aiLastError = msg
                self.markAssistantErrorIfEmpty(msg, sessionID: targetSessionID, messageID: assistantMessageID)
                self.persistAISessions()
            }
        }
    }

    func stopAIGeneration() {
        aiActiveStreamID = UUID()
        aiStreamTask?.cancel()
        aiStreamTask = nil
        aiRouter.cancelAllCLISubprocesses()
        if isAIStreaming {
            isAIStreaming = false
            persistAISessions()
        }
    }

    func retryLastAIMessage() {
        guard let idx = activeAISessionIndex,
              let lastUser = aiSessions[idx].messages.last(where: { $0.role == .user }) else { return }
        // Remove trailing error/empty assistant placeholder before retrying
        if let last = aiSessions[idx].messages.last, last.role == .assistant && (last.isError || last.content.isEmpty) {
            aiSessions[idx].messages.removeLast()
        }
        sendAIMessage(lastUser.content)
    }

    private func appendAssistantChunk(_ chunk: String, sessionID: UUID, messageID: UUID) {
        guard let sIdx = aiSessions.firstIndex(where: { $0.id == sessionID }),
              let mIdx = aiSessions[sIdx].messages.firstIndex(where: { $0.id == messageID }) else { return }
        aiSessions[sIdx].messages[mIdx].content.append(chunk)
        aiSessions[sIdx].updatedAt = Date()
    }

    private func markAssistantErrorIfEmpty(_ errorMessage: String, sessionID: UUID, messageID: UUID) {
        guard let sIdx = aiSessions.firstIndex(where: { $0.id == sessionID }),
              let mIdx = aiSessions[sIdx].messages.firstIndex(where: { $0.id == messageID }) else { return }
        if aiSessions[sIdx].messages[mIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aiSessions[sIdx].messages[mIdx].content = errorMessage
            aiSessions[sIdx].messages[mIdx].isError = true
        }
    }

    // MARK: - Contextual One-Click AI Actions

    func openAIAssistant() {
        openRightTab(.ai)
    }

    func triggerAIQuickAction(_ action: AIQuickActionKind, replayStep: ExecutedStepRecord? = nil) {
        openRightTab(.ai)
        if let replayStep {
            pinnedAIReplayStep = replayStep
        }

        let prompt: String
        switch action {
        case .explain:
            aiEnabledContextKinds = [.activeFile, .selection, .codeceptAPI]
            prompt = editorSelectedText.isEmpty
                ? "Explain what this CodeceptJS file does, step by step, and highlight any potential flakiness."
                : "Explain the selected code in context and point out any potential issues or CodeceptJS edge cases."

        case .refactor:
            aiEnabledContextKinds = [.activeFile, .selection, .codeceptAPI]
            prompt = editorSelectedText.isEmpty
                ? "Refactor this CodeceptJS test to be cleaner, more maintainable, and use resilient locators. Return the updated code in a fenced code block."
                : "Refactor and improve the selected code for clarity, stability, and CodeceptJS 4.x best practices. Return the replacement code in a fenced code block."

        case .generateScenario:
            aiEnabledContextKinds = [.activeFile, .selection, .codeceptAPI]
            prompt = "Generate a complete, idiomatic CodeceptJS 4.x Scenario matching this file's style, helper, and available `I.*` methods. Return clean runnable code in a fenced code block."

        case .fixSelection:
            aiEnabledContextKinds = [.activeFile, .selection, .consoleErrors, .codeceptAPI]
            prompt = "Review the selected code for brittle locators, missing waits, or CodeceptJS issues and provide a fixed replacement in a fenced code block."

        case .diagnoseConsoleErrors:
            aiEnabledContextKinds = [.activeFile, .consoleErrors, .codeceptAPI]
            prompt = "Diagnose the CodeceptJS test failure from the attached console errors. Explain the root cause and provide the exact fix in a fenced code block."

        case .debugReplayFailure:
            aiEnabledContextKinds = [.activeFile, .replayFailure, .consoleErrors, .codeceptAPI]
            prompt = "Debug this failing CodeceptJS Replay step using its error, DOM snapshot, and network/console diagnostics. Explain why it failed and provide a resilient code fix in a fenced code block."
        }

        if activeAIProfile == nil {
            aiComposerText = prompt
            return
        }
        sendAIMessage(prompt)
    }

    // MARK: - Safe Diff Preview & Undo-Tracked Editor Apply

    private func validateSafeEditorMutationTarget(filePath: String) -> Bool {
        let targetURL = URL(fileURLWithPath: filePath).standardizedFileURL.resolvingSymlinksInPath()
        if AIMediaAttachmentProcessor.isBlockedSecretFile(url: targetURL)
            || AIMediaAttachmentProcessor.isBlockedSecretFile(url: URL(fileURLWithPath: filePath)) {
            showBanner("Blocked modifying sensitive file '\(targetURL.lastPathComponent)' via AI.", isError: true)
            return false
        }
        if let rootURL = workspace?.rootURL.standardizedFileURL.resolvingSymlinksInPath() {
            let rootPath = rootURL.path
            let fileResolvedPath = targetURL.path
            if fileResolvedPath != rootPath && !fileResolvedPath.hasPrefix(rootPath + "/") {
                showBanner("Blocked AI edit outside active workspace ('\(targetURL.lastPathComponent)').", isError: true)
                return false
            }
        }
        return true
    }

    func updateEditorSelection(text: String, range: NSRange, lineRange: ClosedRange<Int>?) {
        editorSelectedText = text
        editorSelectedRange = range
        editorSelectedLineRange = lineRange
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aiEnabledContextKinds.insert(.selection)
        }
    }

    func prepareAIDiffPreview(code: String, language: String) {
        guard aiPermissionMode.allowsEditorEdits else {
            showBanner("AI is in Read-Only mode. Switch permission mode to Ask to Proceed or Full Permissions to edit files.", isError: true)
            return
        }
        guard let tab = activeTab else {
            showBanner("Open a file in the editor before applying AI code.", isError: true)
            return
        }
        guard validateSafeEditorMutationTarget(filePath: tab.filePath) else { return }

        let cleanCode = code
        let hasSelection = !editorSelectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && editorSelectedRange.length > 0

        if hasSelection, let lineRange = editorSelectedLineRange {
            let diff = AICodeDiffEngine.computeDiff(original: editorSelectedText, proposed: cleanCode)
            pendingAIDiffPreview = AIPendingDiffPreview(
                filePath: tab.filePath,
                relativePath: tab.relativePath,
                language: language.isEmpty ? tab.language : language,
                applyMode: .replaceSelection(editorSelectedRange, startLine: lineRange.lowerBound, endLine: lineRange.upperBound),
                originalText: editorSelectedText,
                proposedText: cleanCode,
                diffResult: diff
            )
        } else {
            let diff = AICodeDiffEngine.computeDiff(original: tab.content, proposed: cleanCode)
            pendingAIDiffPreview = AIPendingDiffPreview(
                filePath: tab.filePath,
                relativePath: tab.relativePath,
                language: language.isEmpty ? tab.language : language,
                applyMode: .replaceDocument,
                originalText: tab.content,
                proposedText: cleanCode,
                diffResult: diff
            )
        }
    }

    func insertAICodeAtCursor(_ code: String) {
        guard aiPermissionMode.allowsEditorEdits else {
            showBanner("AI is in Read-Only mode. Switch permission mode to Ask to Proceed or Full Permissions to edit files.", isError: true)
            return
        }
        guard let tab = activeTab else {
            showBanner("Open a file in the editor to insert code.", isError: true)
            return
        }
        guard validateSafeEditorMutationTarget(filePath: tab.filePath) else { return }
        pendingEditorMutation = AIEditorMutationRequest(
            filePath: tab.filePath,
            mode: .insertAtSelection,
            text: code
        )
        editorMutationTrigger += 1
        showBanner("Inserted AI snippet into \(tab.name) (⌘Z to undo)")
    }

    func applyAICodeDirectly(_ code: String, language: String) {
        guard aiPermissionMode == .fullWorkspace else {
            prepareAIDiffPreview(code: code, language: language)
            return
        }
        guard let tab = activeTab else {
            showBanner("Open a file in the editor before applying AI code.", isError: true)
            return
        }
        guard validateSafeEditorMutationTarget(filePath: tab.filePath) else { return }

        let hasSelection = !editorSelectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && editorSelectedRange.length > 0
        let mutationMode: AIEditorMutationRequest.Mode = hasSelection
            ? .replaceRange(editorSelectedRange)
            : .replaceDocument

        pendingEditorMutation = AIEditorMutationRequest(
            filePath: tab.filePath,
            mode: mutationMode,
            text: code
        )
        editorMutationTrigger += 1
        showBanner("Applied AI changes directly to \(tab.name) (⌘Z to undo, ⌘S to save)")
    }

    func confirmApplyAIDiffPreview() {
        guard aiPermissionMode.allowsEditorEdits else {
            pendingAIDiffPreview = nil
            showBanner("AI is in Read-Only mode. Switch permission mode to apply edits.", isError: true)
            return
        }
        guard let preview = pendingAIDiffPreview else { return }
        pendingAIDiffPreview = nil
        guard validateSafeEditorMutationTarget(filePath: preview.filePath) else { return }

        let mutationMode: AIEditorMutationRequest.Mode
        switch preview.applyMode {
        case .replaceSelection(let range, _, _):
            mutationMode = .replaceRange(range)
        case .replaceDocument:
            mutationMode = .replaceDocument
        }

        pendingEditorMutation = AIEditorMutationRequest(
            filePath: preview.filePath,
            mode: mutationMode,
            text: preview.proposedText
        )
        editorMutationTrigger += 1
        showBanner("Applied AI changes to \(URL(fileURLWithPath: preview.filePath).lastPathComponent) (⌘Z to undo, ⌘S to save)")
    }

    func copyCodeceptAIConfigSnippet(for profile: AIProviderProfile) {
        let snippet = AICodeceptBridge.configSnippet(for: profile)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        showBanner("Copied CodeceptJS ai: { request } snippet to clipboard")
    }
}

extension AIProviderProfile {
    var shortDisplayTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.shortName : trimmed
    }
}
