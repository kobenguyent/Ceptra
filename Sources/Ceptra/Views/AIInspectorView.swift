import AppKit
import CeptraCore
import SwiftUI
import UniformTypeIdentifiers

struct AIInspectorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var copiedBlockID: String? = nil
    @State private var isComposerFocused: Bool = false
    @State private var isComposerHovered: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var composerHeight: CGFloat = 48
    @State private var isThreadPinnedToBottom: Bool = true
    @State private var isThreadScrolledPastTop: Bool = false
    @State private var isPointerOverThread: Bool = false
    @State private var lastAutoScrollTime: Date = .distantPast
    @State private var scrollWheelMonitor: Any? = nil
    @State private var previewImageItem: AIPreviewImageItem? = nil
    @State private var slashAutocompleteIndex: Int = 0
    @State private var dismissedSlashQuery: String? = nil

    private var activeMessages: [AIChatMessage] {
        appState.activeAISession?.messages ?? []
    }

    private var availableAttachments: [AIContextAttachment] {
        appState.availableAIContextAttachments
    }

    private var activeSlashQueryMatch: AISlashQueryMatch? {
        guard let match = AISkillRegistry.activeSlashQuery(in: appState.aiComposerText) else {
            return nil
        }
        if dismissedSlashQuery == match.query {
            return nil
        }
        return match
    }

    private var activeSlashMatches: [AISkillDescriptor] {
        guard let match = activeSlashQueryMatch else { return [] }
        return AISkillRegistry.filterSkills(appState.aiAvailableSkills, query: match.query)
    }

    private var isSlashMenuVisible: Bool {
        !activeSlashMatches.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            providerHeaderBar

            Divider().overlay(CeptraTheme.border)

            if appState.aiProfiles.isEmpty {
                onboardingEmptyState
            } else if activeMessages.isEmpty {
                readyEmptyState
            } else {
                messageThreadList
            }

            if let err = appState.aiLastError, !err.isEmpty {
                errorBanner(err)
            }

            Divider().overlay(CeptraTheme.border)

            composerArea
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(CeptraTheme.sidebarBG)
        .onAppear {
            if appState.aiSessions.isEmpty {
                appState.loadAISessionsForWorkspace(rootPath: appState.workspace?.rootURL.path ?? "global")
            }
            if appState.detectedAICLIs.isEmpty {
                appState.refreshDetectedAICLIs()
            }
            if appState.aiAvailableSkills.isEmpty {
                appState.refreshAISkills()
            }
            Task { await appState.refreshOllamaStatus() }
        }
        .onChange(of: appState.aiComposerText) { _, newValue in
            slashAutocompleteIndex = 0
            if !newValue.hasPrefix("/") {
                dismissedSlashQuery = nil
            } else if let q = AISkillRegistry.activeSlashQuery(in: newValue)?.query, q != dismissedSlashQuery {
                dismissedSlashQuery = nil
            }
        }
        .sheet(item: $previewImageItem) { item in
            AIMediaPreviewSheet(item: item)
        }
        .sheet(isPresented: $appState.showingAISkillsSheet) {
            AISkillsBrowserSheet()
                .environmentObject(appState)
        }
    }

    // MARK: - Top Provider & Model Switcher Header

    private var providerHeaderBar: some View {
        HStack(spacing: 6) {
            if let active = appState.activeAIProfile {
                CeptraGlassDropdown(
                    arrowEdge: .bottom,
                    minWidth: 278,
                    maxWidth: 318,
                    maxHeight: 400,
                    onOpen: {
                        Task { await appState.refreshOllamaStatus(force: false) }
                    }
                ) { isOpen in
                    CeptraMenuPillLabel(
                        title: active.shortDisplayTitle,
                        titleFont: .system(size: 13, weight: .semibold),
                        titleColor: CeptraTheme.textPrimary,
                        accentBorder: isOpen ? CeptraTheme.accent : nil,
                        tint: CeptraTheme.canvasBG,
                        tintOpacity: 0.72,
                        horizontalPadding: 10,
                        verticalPadding: 5.5,
                        cornerRadius: 7.5,
                        showChevron: true,
                        isOpen: isOpen
                    ) {
                        ZStack {
                            if appState.isAIStreaming {
                                Circle()
                                    .fill(CeptraTheme.accent.opacity(0.28))
                                    .frame(width: 12, height: 12)
                            }
                            Circle()
                                .fill(connectionDotColor(for: active))
                                .frame(width: 7.5, height: 7.5)
                        }
                        .frame(width: 10, height: 10)
                    }
                } content: {
                    AIProviderSwitcherPopoverContent(active: active)
                        .environmentObject(appState)
                }
                .fixedSize(horizontal: false, vertical: true)
                .help("Switch AI Provider (\(active.shortDisplayTitle))")
            } else {
                Button {
                    appState.openAIProviderSettings(addGallery: true)
                } label: {
                    CeptraMenuPillLabel(
                        title: "Connect AI Provider…",
                        titleFont: .system(size: 12.5, weight: .semibold),
                        titleColor: CeptraTheme.textPrimary,
                        accentBorder: CeptraTheme.accent,
                        tint: CeptraTheme.accent,
                        tintOpacity: 0.12,
                        horizontalPadding: 10,
                        verticalPadding: 5.5,
                        cornerRadius: 7.5,
                        showChevron: false,
                        isOpen: false
                    ) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(CeptraTheme.accent)
                    }
                }
                .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.975))
            }

            Spacer(minLength: 4)

            if !appState.savedAISessions.isEmpty || appState.aiSessions.count > 1 {
                CeptraGlassDropdown(arrowEdge: .bottom, minWidth: 276, maxWidth: 320, maxHeight: 380) { isOpen in
                    AIHeaderIconButtonChrome(systemImage: "clock", isActive: isOpen)
                } content: {
                    AIRecentChatsPopoverContent()
                        .environmentObject(appState)
                }
                .help("Recent AI Chats")
            }

            AIHeaderIconButton(systemImage: "square.and.pencil", helpText: "New Chat") {
                appState.startNewAIChat()
            }

            AIHeaderIconButton(systemImage: "slider.horizontal.3", helpText: "Configure AI Providers") {
                appState.openAIProviderSettings(selecting: appState.activeAIProfile?.id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CeptraTheme.panelBG)
    }

    private func headerSubtitle(for profile: AIProviderProfile) -> String {
        if profile.kind == .ollama {
            switch appState.ollamaStatus {
            case .notInstalled: return "Setup needed"
            case .installedNotRunning: return "Stopped"
            case .runningNoModels: return "No models"
            case .remoteUnreachable: return "Offline"
            case .running(let models):
                if !profile.modelID.isEmpty { return profile.modelID }
                return models.first?.name ?? "No models"
            case .unknown:
                return profile.modelID.isEmpty ? "Checking…" : profile.modelID
            }
        }
        if profile.kind.requiresAPIKey && !appState.hasAPIKey(for: profile.id) {
            return "Key needed"
        }
        return profile.modelID.isEmpty ? profile.kind.shortName : profile.modelID
    }

    private func connectionDotColor(for profile: AIProviderProfile) -> Color {
        if appState.isAIStreaming { return CeptraTheme.accent }
        if profile.kind == .ollama {
            switch appState.ollamaStatus {
            case .running(let models):
                let hasActiveModel = !profile.modelID.isEmpty && models.contains(where: { $0.name == profile.modelID })
                return hasActiveModel ? CeptraTheme.success : CeptraTheme.warning
            case .notInstalled, .installedNotRunning, .runningNoModels:
                return CeptraTheme.warning
            case .remoteUnreachable:
                return CeptraTheme.failure
            case .unknown:
                return CeptraTheme.textMuted
            }
        }
        if let status = appState.aiConnectionStatusByProfileID[profile.id] {
            return status.ok ? CeptraTheme.success : CeptraTheme.failure
        }
        if profile.kind.requiresAPIKey && !appState.hasAPIKey(for: profile.id) {
            return CeptraTheme.warning
        }
        if profile.kind.isCLI {
            let found = appState.detectedAICLIs.first(where: { $0.kind == profile.kind })?.isInstalled ?? false
            return found ? CeptraTheme.cyan : CeptraTheme.warning
        }
        return CeptraTheme.textMuted
    }

    private var ollamaOnboardingSubtitle: String {
        switch appState.ollamaStatus {
        case .running(let models):
            return "Running on this Mac · \(models.count) local model\(models.count == 1 ? "" : "s") ready"
        case .runningNoModels:
            return "Running on this Mac · 1-click install a coding model"
        case .installedNotRunning:
            return "Installed on this Mac · click to start local server"
        case .notInstalled, .unknown, .remoteUnreachable:
            return "Private & free · guided 1-click install & model downloader"
        }
    }

    // MARK: - Onboarding (No Provider Yet)

    private var onboardingEmptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect an AI Provider")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Text("Write CodeceptJS scenarios, harden flaky locators, and debug failing Replay traces using local models, cloud APIs, or your signed-in CLI agents.")
                        .font(.system(size: 12.5))
                        .lineSpacing(2.5)
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 9) {
                    AIStarterActionCard(
                        title: "Connect Local Ollama",
                        subtitle: ollamaOnboardingSubtitle,
                        icon: "desktopcomputer",
                        tint: CeptraTheme.success,
                        trailingIcon: "arrow.right"
                    ) {
                        appState.quickConnectLocalOllama()
                    }

                    AIStarterActionCard(
                        title: "Add Cloud API or Local CLI",
                        subtitle: "Claude, OpenAI, Gemini, GitHub Models, LM Studio, or CLI",
                        icon: "key.fill",
                        tint: CeptraTheme.accent,
                        trailingIcon: "arrow.right"
                    ) {
                        appState.openAIProviderSettings(addGallery: true)
                    }
                }

                let installedCLIs = appState.detectedAICLIs.filter(\.isInstalled)
                if !installedCLIs.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("DETECTED ON YOUR MAC")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.65)
                            .foregroundStyle(CeptraTheme.textMuted)
                        ForEach(installedCLIs) { cli in
                            Button {
                                _ = appState.addAIProfile(kind: cli.kind)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "terminal")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(CeptraTheme.cyan)
                                    Text("Use \(cli.kind.displayName)")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(CeptraTheme.textPrimary)
                                    Spacer()
                                    Text("No API key")
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.success)
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
                            }
                            .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.985))
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ready State With Starter Actions

    private var readyEmptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ceptra AI Assistant")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Text("Attach files, screenshots (⌘V), PDFs, or test videos — or toggle context pills below to share your active file, errors, and Replay DOM trace.")
                        .font(.system(size: 12.5))
                        .lineSpacing(2.5)
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    if appState.activeTab != nil {
                        AIStarterActionCard(
                            title: "Explain Active File",
                            subtitle: appState.activeTab?.name ?? "",
                            icon: "doc.text.magnifyingglass",
                            tint: CeptraTheme.accent
                        ) {
                            appState.triggerAIQuickAction(.explain)
                        }
                        AIStarterActionCard(
                            title: "Generate CodeceptJS Scenario",
                            subtitle: "Uses \(appState.activeHelperDisplayName) & workspace I.* steps",
                            icon: "wand.and.stars",
                            tint: CeptraTheme.violet
                        ) {
                            appState.triggerAIQuickAction(.generateScenario)
                        }
                        AIStarterActionCard(
                            title: "Harden Locators & Waits",
                            subtitle: "Replace brittle selectors with resilient locators",
                            icon: "shield.lefthalf.filled",
                            tint: CeptraTheme.cyan
                        ) {
                            appState.triggerAIQuickAction(.fixSelection)
                        }
                    }
                    if appState.latestFailingReplayStep != nil {
                        AIStarterActionCard(
                            title: "Debug Failing Replay Step",
                            subtitle: "Inspect DOM snapshot, network & console errors",
                            icon: "clock.arrow.circlepath",
                            tint: CeptraTheme.failure
                        ) {
                            appState.triggerAIQuickAction(.debugReplayFailure)
                        }
                    } else if appState.consoleLogs.contains(where: { $0.isError }) {
                        AIStarterActionCard(
                            title: "Diagnose Console Errors",
                            subtitle: "Explain failure cause and suggest fix",
                            icon: "exclamationmark.triangle",
                            tint: CeptraTheme.failure
                        ) {
                            appState.triggerAIQuickAction(.diagnoseConsoleErrors)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message Thread (Smart Auto-Follow + Instant Scroll-Up Freedom)

    private var messageThreadList: some View {
        GeometryReader { viewportGeo in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Color.clear
                                .frame(height: 1)
                                .id("ai-top-anchor")
                                .background(
                                    GeometryReader { g in
                                        Color.clear.preference(
                                            key: AIThreadTopOffsetKey.self,
                                            value: g.frame(in: .named("ai-thread-scroll")).minY
                                        )
                                    }
                                )

                            ForEach(activeMessages) { message in
                                messageCard(message)
                                    .id(message.id)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("ai-bottom-anchor")
                                .background(
                                    GeometryReader { g in
                                        Color.clear.preference(
                                            key: AIThreadBottomOffsetKey.self,
                                            value: g.frame(in: .named("ai-thread-scroll")).maxY
                                        )
                                    }
                                )
                        }
                        .padding(14)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }
                    .coordinateSpace(name: "ai-thread-scroll")
                    .onPreferenceChange(AIThreadTopOffsetKey.self) { topMinY in
                        let scrolledPastTop = (-topMinY) > 120
                        if isThreadScrolledPastTop != scrolledPastTop {
                            isThreadScrolledPastTop = scrolledPastTop
                        }
                    }
                    .onPreferenceChange(AIThreadBottomOffsetKey.self) { bottomMaxY in
                        let distanceFromBottom = bottomMaxY - viewportGeo.size.height
                        if distanceFromBottom > 44 {
                            if isThreadPinnedToBottom {
                                isThreadPinnedToBottom = false
                            }
                        } else if distanceFromBottom <= 20 {
                            if !isThreadPinnedToBottom {
                                isThreadPinnedToBottom = true
                            }
                        }
                    }
                    .onChange(of: activeMessages.last?.content.count) { _, _ in
                        guard appState.isAIStreaming, isThreadPinnedToBottom else { return }
                        let now = Date()
                        guard now.timeIntervalSince(lastAutoScrollTime) >= 0.065 else { return }
                        lastAutoScrollTime = now
                        proxy.scrollTo("ai-bottom-anchor", anchor: .bottom)
                    }
                    .onChange(of: activeMessages.count) { _, _ in
                        isThreadPinnedToBottom = true
                        withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                            proxy.scrollTo("ai-bottom-anchor", anchor: .bottom)
                        }
                    }
                    .onChange(of: appState.activeAISession?.id) { _, _ in
                        isThreadPinnedToBottom = true
                        isThreadScrolledPastTop = false
                    }

                    // Floating Glass Quick-Scroll Controls (↑ Top / ↓ Latest)
                    if isThreadScrolledPastTop || !isThreadPinnedToBottom {
                        HStack(spacing: 5) {
                            if isThreadScrolledPastTop {
                                AIThreadJumpButton(
                                    icon: "arrow.up",
                                    label: isThreadPinnedToBottom ? "Top" : nil,
                                    showPulseDot: false,
                                    helpText: "Scroll to Top"
                                ) {
                                    isThreadPinnedToBottom = false
                                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                                        proxy.scrollTo("ai-top-anchor", anchor: .top)
                                    }
                                }
                            }

                            if !isThreadPinnedToBottom {
                                AIThreadJumpButton(
                                    icon: "arrow.down",
                                    label: appState.isAIStreaming ? "Latest" : nil,
                                    showPulseDot: appState.isAIStreaming,
                                    helpText: "Jump to Latest Message"
                                ) {
                                    isThreadPinnedToBottom = true
                                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                                        proxy.scrollTo("ai-bottom-anchor", anchor: .bottom)
                                    }
                                }
                            }
                        }
                        .padding(.trailing, 12)
                        .padding(.bottom, 10)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing)))
                    }
                }
                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isThreadPinnedToBottom)
                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isThreadScrolledPastTop)
                .onHover { hovering in
                    isPointerOverThread = hovering
                }
                .onAppear {
                    installThreadScrollMonitor()
                }
                .onDisappear {
                    removeThreadScrollMonitor()
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func installThreadScrollMonitor() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if isPointerOverThread && event.scrollingDeltaY > 1.0 && isThreadPinnedToBottom {
                DispatchQueue.main.async {
                    isThreadPinnedToBottom = false
                }
            }
            return event
        }
    }

    private func removeThreadScrollMonitor() {
        if let monitor = scrollWheelMonitor {
            NSEvent.removeMonitor(monitor)
            scrollWheelMonitor = nil
        }
    }

    @ViewBuilder
    private func messageCard(_ message: AIChatMessage) -> some View {
        let isUser = message.role == .user
        let isStreamingThis = appState.isAIStreaming && message.id == activeMessages.last?.id && !isUser

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(isUser ? "You" : (message.providerName ?? "AI"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isUser ? CeptraTheme.textSecondary : CeptraTheme.accent)
                if let model = message.modelUsed, !isUser {
                    Text(model)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isStreamingThis {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
            }

            if !message.attachedSummaries.isEmpty {
                let mediaSummaries = message.attachedSummaries.filter { $0.thumbnailBase64 != nil }
                let pillSummaries = message.attachedSummaries.filter { $0.thumbnailBase64 == nil }

                if !mediaSummaries.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(mediaSummaries) { item in
                                AISentThumbnailButton(item: item) { image in
                                    previewImageItem = AIPreviewImageItem(title: item.label, image: image)
                                }
                            }
                        }
                    }
                }

                if !pillSummaries.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(pillSummaries) { item in
                                let isSkillPill = item.kind == .skill
                                HStack(spacing: 3.5) {
                                    Image(systemName: item.kind.symbolName)
                                        .font(.system(size: 9.5))
                                    Text(item.label)
                                        .font(.system(size: 10.5, weight: isSkillPill ? .semibold : .regular, design: .monospaced))
                                    if item.wasRedacted {
                                        Image(systemName: "lock.shield")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(CeptraTheme.success)
                                    }
                                }
                                .foregroundStyle(isSkillPill ? CeptraTheme.violet : CeptraTheme.textSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(
                                    isSkillPill ? CeptraTheme.violet.opacity(0.14) : CeptraTheme.hoverBG,
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        isSkillPill ? CeptraTheme.violet.opacity(0.35) : Color.clear,
                                        lineWidth: 0.75
                                    )
                                )
                            }
                        }
                    }
                }
            }

            if message.isError {
                Text(message.content)
                    .font(.system(size: 12.5))
                    .lineSpacing(2.5)
                    .foregroundStyle(CeptraTheme.failure)
                    .textSelection(.enabled)
            } else if isUser {
                Text(message.content)
                    .font(.system(size: 13))
                    .lineSpacing(2.5)
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if message.content.isEmpty && isStreamingThis {
                Text("Thinking…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(CeptraTheme.textMuted)
            } else {
                let segments = AICodeDiffEngine.parseMarkdownSegments(message.content)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(segments) { segment in
                        switch segment {
                        case .prose(_, let text):
                            proseMarkdownText(text)
                        case .code(let block):
                            codeBlockCard(block)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(
            isUser ? CeptraTheme.elevatedBG.opacity(0.65) : CeptraTheme.canvasBG,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(message.isError ? CeptraTheme.failure.opacity(0.45) : CeptraTheme.border, lineWidth: 1)
        )
        .clipped()
    }

    @ViewBuilder
    private func proseMarkdownText(_ text: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(CeptraTheme.textPrimary)
                .textSelection(.enabled)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(CeptraTheme.textPrimary)
                .textSelection(.enabled)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeBlockCard(_ block: AIExtractedCodeBlock) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(block.language.isEmpty ? "code" : block.language)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(block.code, forType: .string)
                    copiedBlockID = block.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        if copiedBlockID == block.id { copiedBlockID = nil }
                    }
                } label: {
                    Label(copiedBlockID == block.id ? "Copied" : "Copy", systemImage: copiedBlockID == block.id ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(copiedBlockID == block.id ? CeptraTheme.success : CeptraTheme.textSecondary)
                }
                .buttonStyle(.plain)

                if appState.activeTab != nil {
                    switch appState.aiPermissionMode {
                    case .readOnly:
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                            Text("Read-Only")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(CeptraTheme.textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CeptraTheme.hoverBG, in: Capsule())
                        .help("Read-Only mode active — switch permission mode below to apply edits")

                    case .askToProceed:
                        Button {
                            appState.insertAICodeAtCursor(block.code)
                        } label: {
                            Label("Insert", systemImage: "text.insert")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(CeptraTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Insert at current cursor position (⌘Z to undo)")

                        Button {
                            appState.prepareAIDiffPreview(code: block.code, language: block.language)
                        } label: {
                            Label("Preview & Apply", systemImage: "arrow.left.arrow.right")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(CeptraTheme.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(CeptraTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Review unified diff before applying to active editor tab")

                    case .fullWorkspace:
                        Button {
                            appState.prepareAIDiffPreview(code: block.code, language: block.language)
                        } label: {
                            Label("Diff", systemImage: "arrow.left.arrow.right")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(CeptraTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Optional: inspect unified diff first")

                        Button {
                            appState.applyAICodeDirectly(block.code, language: block.language)
                        } label: {
                            Label("Apply", systemImage: "bolt.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(CeptraTheme.accentWarm)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(CeptraTheme.accentWarm.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Full Workspace mode: apply directly into active editor tab (⌘Z to undo)")
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(CeptraTheme.panelBG)

            Divider().overlay(CeptraTheme.subtleBorder)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(block.code)
                    .font(.system(size: min(17, max(11, 12 * appState.editorZoomScale)), design: .monospaced))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .background(CeptraTheme.sidebarBG)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(CeptraTheme.failure)
                .padding(.top, 1.5)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(CeptraTheme.failure)
                .lineLimit(3)
            Spacer(minLength: 4)
            Button("Retry") {
                appState.retryLastAIMessage()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(CeptraTheme.accent)
            .buttonStyle(.plain)

            Button {
                appState.aiLastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CeptraTheme.failure.opacity(0.10))
    }

    // MARK: - Unified Elevated Prompt Composer

    private func selectSlashAutocompleteItem(_ skill: AISkillDescriptor) {
        appState.aiComposerText = ""
        dismissedSlashQuery = nil
        slashAutocompleteIndex = 0
        appState.selectAISkill(skill)
    }

    private func composerPlaceholder(hasAttachments: Bool) -> String {
        if let pinned = appState.aiPinnedSkill {
            if let hint = pinned.argumentHint, !hint.isEmpty {
                return "\(pinned.slashCommand) \(hint) — or press ↩ to run…"
            }
            return "Add optional instructions for \(pinned.slashCommand) or press ↩ to run…"
        }
        if hasAttachments {
            return "Describe what to inspect or press ↩ to analyze…"
        }
        return "Ask AI, type / for skills, paste (⌘V), or drop files…"
    }

    private var composerArea: some View {
        let hasText = !appState.aiComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !appState.aiPendingAttachments.isEmpty
        let hasPinnedSkill = appState.aiPinnedSkill != nil
        let canSend = hasText || hasAttachments || hasPinnedSkill
        let slashMatches = activeSlashMatches

        return VStack(spacing: 6) {
            // Instant Liquid Glass Slash Autocomplete Palette (↑/↓ · ↩/⇥ · Esc)
            if !slashMatches.isEmpty {
                AISlashAutocompletePanel(
                    matches: slashMatches,
                    selectedIndex: min(max(0, slashAutocompleteIndex), max(0, slashMatches.count - 1)),
                    onSelect: { skill in
                        selectSlashAutocompleteItem(skill)
                    },
                    onOpenManager: {
                        appState.aiComposerText = ""
                        dismissedSlashQuery = nil
                        appState.showingAISkillsSheet = true
                    }
                )
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }

            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    // Integrated Attach + /Skills + Workspace Context Pill Strip
                    HStack(spacing: 6) {
                        CeptraGlassDropdown(
                            arrowEdge: .top,
                            minWidth: 264,
                            maxWidth: 304,
                            maxHeight: 360
                        ) { isOpen in
                            HStack(spacing: 5) {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Attach")
                                    .font(.system(size: 12.5, weight: .medium))
                                if hasAttachments {
                                    Text("\(appState.aiPendingAttachments.count)")
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(CeptraTheme.accent, in: Capsule())
                                }
                            }
                            .foregroundStyle(isOpen || hasAttachments ? CeptraTheme.accent : CeptraTheme.textSecondary)
                            .padding(.horizontal, 9.5)
                            .padding(.vertical, 5)
                            .background(
                                (isOpen || hasAttachments) ? CeptraTheme.accent.opacity(0.12) : CeptraTheme.panelBG.opacity(0.75),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    (isOpen || hasAttachments) ? CeptraTheme.accent.opacity(0.45) : CeptraTheme.border,
                                    lineWidth: 0.75
                                )
                            )
                            .contentShape(Capsule())
                        } content: {
                            AIAttachMediaPopoverContent()
                                .environmentObject(appState)
                        }
                        .fixedSize()
                        .help("Attach files, screenshots, PDFs, or test videos (or drag & drop / ⌘V paste)")

                        CeptraGlassDropdown(
                            arrowEdge: .top,
                            minWidth: 296,
                            maxWidth: 332,
                            maxHeight: 400,
                            onOpen: {
                                appState.refreshAISkills()
                            }
                        ) { isOpen in
                            HStack(spacing: 4.5) {
                                Image(systemName: "slash.circle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(hasPinnedSkill ? (appState.aiPinnedSkill?.slashCommand ?? "Skills") : "Skills")
                                    .font(.system(size: 12.5, weight: hasPinnedSkill ? .semibold : .medium, design: hasPinnedSkill ? .monospaced : .default))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(isOpen || hasPinnedSkill ? CeptraTheme.violet : CeptraTheme.textSecondary)
                            .padding(.horizontal, 9.5)
                            .padding(.vertical, 5)
                            .background(
                                (isOpen || hasPinnedSkill) ? CeptraTheme.violet.opacity(0.13) : CeptraTheme.panelBG.opacity(0.75),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    (isOpen || hasPinnedSkill) ? CeptraTheme.violet.opacity(0.48) : CeptraTheme.border,
                                    lineWidth: 0.75
                                )
                            )
                            .contentShape(Capsule())
                        } content: {
                            AISkillsQuickPopoverContent()
                                .environmentObject(appState)
                        }
                        .fixedSize()
                        .help("Invoke /commands or SKILL.md agent skills (works on Local Ollama & all providers)")

                        if !availableAttachments.isEmpty {
                            Rectangle()
                                .fill(CeptraTheme.border)
                                .frame(width: 1, height: 14)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(availableAttachments) { item in
                                        let isOn = appState.aiEnabledContextKinds.contains(item.kind)
                                        AIContextPillButton(
                                            item: item,
                                            isOn: isOn,
                                            formattedSize: formatBytes(item.byteCount)
                                        ) {
                                            withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                                                appState.toggleAIContextKind(item.kind)
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 9)
                    .padding(.bottom, 7)

                    Rectangle()
                        .fill(CeptraTheme.subtleBorder)
                        .frame(height: 0.75)
                        .padding(.horizontal, 10)

                    // Pinned Active Slash Command / Skill Banner
                    if let pinned = appState.aiPinnedSkill {
                        HStack(spacing: 7) {
                            Image(systemName: pinned.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(CeptraTheme.violet)
                            Text(pinned.slashCommand)
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(CeptraTheme.violet)
                            Text(pinned.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CeptraTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(pinned.source.badgeLabel)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(CeptraTheme.violet)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1.5)
                                .background(CeptraTheme.violet.opacity(0.14), in: Capsule())
                            Button {
                                withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                                    appState.clearAIPinnedSkill()
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(CeptraTheme.textMuted)
                                    .frame(width: 17, height: 17)
                                    .background(CeptraTheme.hoverBG, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove active skill")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(CeptraTheme.violet.opacity(0.07))

                        Rectangle()
                            .fill(CeptraTheme.subtleBorder)
                            .frame(height: 0.75)
                            .padding(.horizontal, 10)
                    }

                    // Pending User Media & File Attachment Cards
                    if hasAttachments {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(appState.aiPendingAttachments) { attachment in
                                    AIPendingAttachmentCard(
                                        attachment: attachment,
                                        onPreview: { image in
                                            previewImageItem = AIPreviewImageItem(title: attachment.displayName, image: image)
                                        },
                                        onRemove: {
                                            withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                                                appState.removeAIPendingAttachment(id: attachment.id)
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }

                        Rectangle()
                            .fill(CeptraTheme.subtleBorder)
                            .frame(height: 0.75)
                            .padding(.horizontal, 10)
                    }

                    // Multi-line Auto-Growing Prompt Editor (↩ Send · ⇧↩ New line · ⌘V Paste Image/Files · / Skills)
                    ZStack(alignment: .topLeading) {
                        if appState.aiComposerText.isEmpty {
                            Text(composerPlaceholder(hasAttachments: hasAttachments))
                                .font(.system(size: 13))
                                .foregroundStyle(CeptraTheme.textMuted)
                                .padding(.top, 2)
                                .allowsHitTesting(false)
                        }

                        AIComposerTextView(
                            text: $appState.aiComposerText,
                            measuredHeight: $composerHeight,
                            minHeight: 48,
                            maxHeight: 156,
                            isSlashMenuOpen: isSlashMenuVisible,
                            onSubmit: {
                                appState.sendAIMessage()
                            },
                            onFocusChanged: { focused in
                                withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                                    isComposerFocused = focused
                                }
                            },
                            onPasteImage: { image in
                                appState.addAIClipboardImageAttachment(image)
                            },
                            onPasteFileURLs: { urls in
                                appState.addAIAttachments(from: urls)
                            },
                            onSlashMoveUp: {
                                let count = activeSlashMatches.count
                                guard count > 0 else { return }
                                slashAutocompleteIndex = (slashAutocompleteIndex - 1 + count) % count
                            },
                            onSlashMoveDown: {
                                let count = activeSlashMatches.count
                                guard count > 0 else { return }
                                slashAutocompleteIndex = (slashAutocompleteIndex + 1) % count
                            },
                            onSlashConfirm: {
                                let list = activeSlashMatches
                                guard !list.isEmpty else { return }
                                let idx = min(max(0, slashAutocompleteIndex), list.count - 1)
                                selectSlashAutocompleteItem(list[idx])
                            },
                            onSlashDismiss: {
                                if let q = AISkillRegistry.activeSlashQuery(in: appState.aiComposerText)?.query {
                                    dismissedSlashQuery = q
                                }
                            }
                        )
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: composerHeight)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 9)
                    .padding(.bottom, 6)

                    // Integrated Bottom Composer Action Bar (Model Switcher Pill + Send/Stop)
                    HStack(spacing: 7) {
                        if let active = appState.activeAIProfile {
                            let needsAction = modelPillNeedsAction(for: active)
                            CeptraGlassDropdown(
                                arrowEdge: .top,
                                minWidth: 280,
                                maxWidth: 320,
                                maxHeight: 380,
                                onOpen: {
                                    if active.kind == .ollama {
                                        Task { await appState.refreshOllamaStatus(for: active, force: false) }
                                    }
                                }
                            ) { isOpen in
                                CeptraMenuPillLabel(
                                    title: headerSubtitle(for: active),
                                    titleFont: .system(size: 12, weight: .medium, design: .monospaced),
                                    titleColor: needsAction ? CeptraTheme.warning : CeptraTheme.textPrimary,
                                    accentBorder: isOpen ? CeptraTheme.accent : (needsAction ? CeptraTheme.warning.opacity(0.45) : nil),
                                    tint: needsAction ? CeptraTheme.warning : CeptraTheme.panelBG,
                                    tintOpacity: needsAction ? 0.10 : 0.65,
                                    horizontalPadding: 9,
                                    verticalPadding: 5,
                                    cornerRadius: 7.5,
                                    showChevron: true,
                                    isOpen: isOpen
                                ) {
                                    Image(systemName: needsAction ? "exclamationmark.circle.fill" : active.kind.symbolName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(needsAction ? CeptraTheme.warning : CeptraTheme.textSecondary)
                                }
                            } content: {
                                AIModelSwitcherPopoverContent(active: active)
                                    .environmentObject(appState)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .help("Switch Model for \(active.shortDisplayTitle) (↩ Send · ⇧↩ New line)")
                        } else if appState.isAIStreaming {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(CeptraTheme.accent)
                                    .frame(width: 6.5, height: 6.5)
                                Text("Generating…")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(CeptraTheme.textSecondary)
                            }
                        }

                        Spacer(minLength: 4)

                        // Permission Mode Switcher Pill (Read-Only / Ask to Proceed / Full Permissions)
                        let mode = appState.aiPermissionMode
                        let modeTint = permissionModeTint(for: mode)
                        CeptraGlassDropdown(
                            arrowEdge: .top,
                            minWidth: 280,
                            maxWidth: 316,
                            maxHeight: 330
                        ) { isOpen in
                            CeptraMenuPillLabel(
                                title: mode.shortLabel,
                                titleFont: .system(size: 11.5, weight: .semibold),
                                titleColor: modeTint,
                                accentBorder: isOpen ? modeTint : modeTint.opacity(0.35),
                                tint: modeTint,
                                tintOpacity: isOpen ? 0.16 : 0.10,
                                horizontalPadding: 8.5,
                                verticalPadding: 5,
                                cornerRadius: 7.5,
                                showChevron: true,
                                isOpen: isOpen
                            ) {
                                Image(systemName: mode.symbolName)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(modeTint)
                            }
                        } content: {
                            AIPermissionModePopoverContent()
                                .environmentObject(appState)
                        }
                        .fixedSize()
                        .help("AI Permission Mode: \(mode.displayName) — \(mode.summary)")

                        if canSend && !appState.isAIStreaming {
                            Button {
                                appState.aiComposerText = ""
                                appState.clearAIPendingAttachments()
                                appState.clearAIPinnedSkill()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(CeptraTheme.textMuted.opacity(0.85))
                                    .frame(width: 26, height: 26)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Clear Prompt & Attachments")
                            .transition(.opacity)
                        }

                        if appState.isAIStreaming {
                            Button {
                                appState.stopAIGeneration()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 10.5, weight: .bold))
                                    Text("Stop")
                                        .font(.system(size: 12.5, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(CeptraTheme.failure, in: Capsule())
                            }
                            .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.96))
                            .help("Stop Generation")
                        } else {
                            Button {
                                appState.sendAIMessage()
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundStyle(canSend ? .white : CeptraTheme.textSecondary)
                                    .frame(width: 30, height: 30)
                                    .background(
                                        canSend ? CeptraTheme.accent : CeptraTheme.hoverBG,
                                        in: RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                                            .strokeBorder(canSend ? Color.white.opacity(0.18) : CeptraTheme.border, lineWidth: 0.75)
                                    )
                                    .shadow(color: canSend ? CeptraTheme.accent.opacity(0.32) : .clear, radius: 6, y: 2)
                            }
                            .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.94))
                            .disabled(!canSend)
                            .help("Send Prompt (↩ · ⇧↩ New line)")
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.bottom, 9)
                    .padding(.top, 2)
                }

                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CeptraTheme.accent.opacity(0.10))
                        .overlay(
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Drop files, images, PDFs, or videos to attach")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(CeptraTheme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(CeptraTheme.accent.opacity(0.45), lineWidth: 1))
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .background(
                CeptraTheme.canvasBG,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isDropTargeted
                            ? CeptraTheme.accent
                            : (isComposerFocused
                                ? CeptraTheme.accent.opacity(0.68)
                                : (isComposerHovered ? CeptraTheme.borderStrong : CeptraTheme.border)),
                        lineWidth: (isDropTargeted || isComposerFocused) ? 1.5 : 1
                    )
            )
            .shadow(
                color: (isDropTargeted || isComposerFocused) ? CeptraTheme.accent.opacity(0.14) : Color.black.opacity(0.12),
                radius: (isDropTargeted || isComposerFocused) ? 10 : 5,
                y: 2
            )
            .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isComposerFocused)
            .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isComposerHovered)
            .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isDropTargeted)
            .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: canSend)
            .onHover { isComposerHovered = $0 }
            .onDrop(of: [.fileURL, .image, .png, .tiff], isTargeted: $isDropTargeted) { providers in
                handleComposerDrop(providers)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(CeptraTheme.panelBG)
    }

    private func handleComposerDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var resolvedURL: URL? = nil
                    if let url = item as? URL {
                        resolvedURL = url
                    } else if let data = item as? Data {
                        resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                    }
                    guard let fileURL = resolvedURL, fileURL.isFileURL else { return }
                    Task { @MainActor in
                        appState.addAIAttachments(from: [fileURL])
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                let suggestedName = provider.suggestedName.map { $0.hasSuffix(".png") ? $0 : "\($0).png" }
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    Task { @MainActor in
                        appState.addAIClipboardImageAttachment(image, displayName: suggestedName)
                    }
                }
            }
        }
        return accepted
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes)B"
        }
        return String(format: "%.1fK", Double(bytes) / 1024.0)
    }

    private func permissionModeTint(for mode: AIPermissionMode) -> Color {
        switch mode {
        case .readOnly: return CeptraTheme.cyan
        case .askToProceed: return CeptraTheme.accent
        case .fullWorkspace: return CeptraTheme.accentWarm
        }
    }

    private func modelPillNeedsAction(for profile: AIProviderProfile) -> Bool {
        if profile.kind == .ollama {
            switch appState.ollamaStatus {
            case .running(let models):
                return models.isEmpty
            case .notInstalled, .installedNotRunning, .runningNoModels, .remoteUnreachable:
                return true
            case .unknown:
                return false
            }
        }
        if profile.kind.requiresAPIKey && !appState.hasAPIKey(for: profile.id) {
            return true
        }
        return false
    }
}

// MARK: - Top Header: Provider-Only Switcher Popover

private struct AIProviderSwitcherPopoverContent: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.ceptraDropdownDismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let active: AIProviderProfile

    private var currentActive: AIProviderProfile {
        appState.activeAIProfile ?? active
    }

    private var unconfiguredInstalledCLIs: [DetectedCLIAgent] {
        let configuredKinds = Set(appState.aiProfiles.map(\.kind))
        return appState.detectedAICLIs.filter { $0.isInstalled && !configuredKinds.contains($0.kind) }
    }

    private var unconfiguredOllamaQuickBadge: (text: String, color: Color) {
        switch appState.ollamaStatus {
        case .running(let models) where !models.isEmpty:
            return ("\(models.count) ready", CeptraTheme.success)
        case .runningNoModels, .running:
            return ("Running", CeptraTheme.accent)
        case .installedNotRunning:
            return ("Stopped", CeptraTheme.warning)
        case .notInstalled, .remoteUnreachable, .unknown:
            return ("Local", CeptraTheme.success)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Section 1: Configured Providers
            HStack(spacing: 6) {
                Text("AI PROVIDER")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(CeptraTheme.textMuted)
                Spacer()
                Text(providerTransportLabel(for: currentActive))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(providerTint(for: currentActive.kind))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(providerTint(for: currentActive.kind).opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 9)
            .padding(.top, 4)
            .padding(.bottom, 2)

            VStack(spacing: 2) {
                ForEach(appState.aiProfiles) { profile in
                    AIProviderPopoverRow(
                        profile: profile,
                        subtitleOverride: providerRowSubtitle(for: profile),
                        isSelected: profile.id == currentActive.id,
                        tint: providerTint(for: profile.kind),
                        badgeText: providerBadgeText(for: profile),
                        badgeColor: providerBadgeColor(for: profile)
                    ) {
                        appState.selectAIProfile(id: profile.id)
                        if profile.kind == .ollama {
                            Task { await appState.refreshOllamaStatus(for: profile, force: false) }
                        }
                        dismiss()
                    }
                }
            }

            // Section 2: Quick-Add Detected Local Ollama & CLIs
            let hasOllamaProfile = appState.aiProfiles.contains(where: { $0.kind == .ollama })
            if !hasOllamaProfile || !unconfiguredInstalledCLIs.isEmpty {
                adaptiveDivider
                Text("DETECTED ON THIS MAC")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(CeptraTheme.textMuted)
                    .padding(.horizontal, 9)
                    .padding(.top, 2)
                    .padding(.bottom, 2)

                VStack(spacing: 2) {
                    if !hasOllamaProfile {
                        let ollamaQuickBadge = unconfiguredOllamaQuickBadge
                        AIQuickActionPopoverRow(
                            title: "Add Ollama (Local)",
                            trailingBadge: ollamaQuickBadge.text,
                            trailingColor: ollamaQuickBadge.color,
                            systemImage: "desktopcomputer",
                            iconColor: CeptraTheme.success
                        ) {
                            let created = appState.addAIProfile(kind: .ollama)
                            Task { await appState.refreshOllamaStatus(for: created, force: true) }
                            dismiss()
                        }
                        .help("Private local AI on your Mac — no API key needed")
                    }

                    ForEach(unconfiguredInstalledCLIs) { cli in
                        AIQuickActionPopoverRow(
                            title: "Add \(cli.kind.displayName)",
                            trailingBadge: "CLI login",
                            trailingColor: CeptraTheme.cyan,
                            systemImage: "plus.circle",
                            iconColor: CeptraTheme.cyan
                        ) {
                            _ = appState.addAIProfile(kind: cli.kind)
                            dismiss()
                        }
                        .help("Uses your local terminal CLI sign-in (detected at \(cli.executablePath ?? "")). For API-key access to Claude, OpenAI, or Gemini, use Configure AI Providers…")
                    }
                }
            }

            // Section 3: Footer Configuration Actions
            adaptiveDivider

            VStack(spacing: 2) {
                if !currentActive.kind.isCLI && currentActive.kind != .ollama {
                    let isTesting = appState.aiTestingProfileID == currentActive.id
                    AIQuickActionPopoverRow(
                        title: isTesting ? "Testing Connection…" : "Test Connection",
                        trailingBadge: connectionLatencyBadge(for: currentActive),
                        trailingColor: connectionBadgeColor(for: currentActive),
                        systemImage: "bolt.horizontal.circle",
                        iconColor: CeptraTheme.textSecondary
                    ) {
                        Task { await appState.testAIProviderConnection(profileID: currentActive.id) }
                    }
                }

                AIQuickActionPopoverRow(
                    title: "Configure AI Providers…",
                    trailingBadge: "\(appState.aiProfiles.count)",
                    trailingColor: CeptraTheme.textMuted,
                    systemImage: "slider.horizontal.3",
                    iconColor: CeptraTheme.accent
                ) {
                    dismiss()
                    appState.openAIProviderSettings(selecting: currentActive.id)
                }
            }
        }
        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: currentActive.id)
    }

    private var adaptiveDivider: some View {
        Rectangle()
            .fill(CeptraTheme.border)
            .frame(height: 0.75)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
    }

    private func providerTint(for kind: AIProviderKind) -> Color {
        switch kind {
        case .ollama: return CeptraTheme.success
        case .anthropic: return CeptraTheme.accentWarm
        case .openAI: return CeptraTheme.success
        case .gemini: return CeptraTheme.accent
        case .githubModels: return CeptraTheme.violet
        case .openAICompatible: return CeptraTheme.textSecondary
        case .claudeCLI, .copilotCLI, .codexCLI: return CeptraTheme.cyan
        }
    }

    private func providerTransportLabel(for profile: AIProviderProfile) -> String {
        if profile.kind.isCLI { return "Local CLI" }
        return profile.sendsDataToCloud ? "Cloud API" : "Local"
    }

    private func providerRowSubtitle(for profile: AIProviderProfile) -> String {
        if profile.kind == .ollama {
            switch appState.ollamaStatus {
            case .notInstalled: return "Not installed on this Mac"
            case .installedNotRunning: return "Local server offline"
            case .runningNoModels: return "No models installed yet"
            case .remoteUnreachable: return "Remote endpoint unreachable"
            case .running(let models):
                if !profile.modelID.isEmpty, models.contains(where: { $0.name == profile.modelID }) {
                    return profile.modelID
                }
                return models.first?.name ?? "Select a model"
            case .unknown:
                return profile.modelID.isEmpty ? "Checking status…" : profile.modelID
            }
        }
        if profile.kind.requiresAPIKey && !appState.hasAPIKey(for: profile.id) {
            return "API key required"
        }
        return profile.modelID.isEmpty ? profile.kind.shortName : profile.modelID
    }

    private func providerBadgeText(for profile: AIProviderProfile) -> String? {
        if profile.kind == .ollama {
            switch appState.ollamaStatus {
            case .running(let m) where !m.isEmpty: return "Ready"
            case .runningNoModels, .running: return "No models"
            case .installedNotRunning: return "Stopped"
            case .notInstalled: return "Setup needed"
            case .remoteUnreachable: return "Offline"
            case .unknown: return "Local"
            }
        }
        if let status = appState.aiConnectionStatusByProfileID[profile.id] {
            if !status.ok { return "Error" }
            if status.latencyMs > 0 { return "\(status.latencyMs)ms" }
            return "Verified"
        }
        if profile.kind.requiresAPIKey && !appState.hasAPIKey(for: profile.id) {
            return "Key needed"
        }
        if profile.kind.isCLI {
            let found = appState.detectedAICLIs.first(where: { $0.kind == profile.kind })?.isInstalled ?? false
            return found ? "CLI login" : "Not installed"
        }
        if !profile.sendsDataToCloud { return "Local" }
        return nil
    }

    private func providerBadgeColor(for profile: AIProviderProfile) -> Color {
        if profile.kind == .ollama {
            switch appState.ollamaStatus {
            case .running(let m) where !m.isEmpty: return CeptraTheme.success
            case .remoteUnreachable: return CeptraTheme.failure
            case .unknown: return CeptraTheme.textMuted
            default: return CeptraTheme.warning
            }
        }
        if let status = appState.aiConnectionStatusByProfileID[profile.id] {
            return status.ok ? CeptraTheme.success : CeptraTheme.failure
        }
        if profile.kind.requiresAPIKey && !appState.hasAPIKey(for: profile.id) {
            return CeptraTheme.warning
        }
        if profile.kind.isCLI {
            let found = appState.detectedAICLIs.first(where: { $0.kind == profile.kind })?.isInstalled ?? false
            return found ? CeptraTheme.cyan : CeptraTheme.warning
        }
        return CeptraTheme.textMuted
    }

    private func connectionLatencyBadge(for profile: AIProviderProfile) -> String? {
        guard let status = appState.aiConnectionStatusByProfileID[profile.id] else { return nil }
        return status.ok ? (status.latencyMs > 0 ? "\(status.latencyMs)ms" : "OK") : "Failed"
    }

    private func connectionBadgeColor(for profile: AIProviderProfile) -> Color {
        guard let status = appState.aiConnectionStatusByProfileID[profile.id] else { return CeptraTheme.textMuted }
        return status.ok ? CeptraTheme.success : CeptraTheme.failure
    }
}

// MARK: - Bottom Composer: Model-Only Switcher Popover

private struct AIModelSwitcherPopoverContent: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.ceptraDropdownDismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let active: AIProviderProfile

    @State private var modelQuery: String = ""
    @State private var showModelSearch: Bool = false

    private var currentActive: AIProviderProfile {
        appState.activeAIProfile ?? active
    }

    private var filteredModels: [String] {
        let all = currentActive.availableModels
        let q = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(all.prefix(32)) }
        return all.filter { $0.localizedCaseInsensitiveContains(q) }.prefix(32).map { $0 }
    }

    private var trimmedQuery: String {
        modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowSearchBar: Bool {
        showModelSearch || currentActive.availableModels.count > 5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("MODEL · \(currentActive.kind.shortName.uppercased())")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(CeptraTheme.textMuted)
                    .lineLimit(1)
                Spacer()

                if currentActive.kind != .ollama && currentActive.availableModels.count <= 5 {
                    Button {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                            showModelSearch.toggle()
                            if !showModelSearch { modelQuery = "" }
                        }
                    } label: {
                        Image(systemName: showModelSearch ? "xmark.circle.fill" : "magnifyingglass")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(showModelSearch ? CeptraTheme.accent : CeptraTheme.textMuted)
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showModelSearch ? "Hide Custom Model Input" : "Filter or Enter Custom Model ID")
                }

                if !currentActive.kind.isCLI {
                    let isFetching = currentActive.kind == .ollama
                        ? appState.isCheckingOllama
                        : (appState.aiFetchingModelsProfileID == currentActive.id)
                    AIInlineRefreshButton(isRefreshing: isFetching) {
                        if currentActive.kind == .ollama {
                            Task { await appState.refreshOllamaStatus(for: currentActive, force: true) }
                        } else {
                            Task { await appState.fetchModelsForAIProfile(profileID: currentActive.id) }
                        }
                    }
                    .help("Refresh available models from \(currentActive.shortDisplayTitle)")
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 4)
            .padding(.bottom, 2)

            if shouldShowSearchBar && currentActive.kind != .ollama {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(CeptraTheme.textMuted)
                    TextField("Filter or type custom model ID…", text: $modelQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .onSubmit {
                            if !trimmedQuery.isEmpty {
                                let target = filteredModels.first ?? trimmedQuery
                                appState.selectAIModel(target, for: currentActive.id)
                                dismiss()
                            }
                        }
                    if !modelQuery.isEmpty {
                        Button {
                            modelQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(CeptraTheme.canvasBG.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CeptraTheme.border, lineWidth: 0.75)
                )
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }

            Group {
                if currentActive.kind == .ollama {
                    ollamaPopoverModelSection(for: currentActive)
                } else if currentActive.kind.requiresAPIKey && !appState.hasAPIKey(for: currentActive.id) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("API key required for \(currentActive.shortDisplayTitle)")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        Text(currentActive.kind.apiKeySetupHint)
                            .font(.system(size: 10.5))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            dismiss()
                            appState.openAIProviderSettings(selecting: currentActive.id)
                        } label: {
                            Text("Add API Key in Keychain…")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(CeptraTheme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.975))
                    }
                    .padding(9)
                    .background(CeptraTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.warning.opacity(0.28), lineWidth: 0.75))
                    .padding(.horizontal, 4)
                } else {
                    VStack(spacing: 2) {
                        ForEach(filteredModels, id: \.self) { model in
                            AIModelPopoverRow(
                                modelID: model,
                                hint: modelCapabilityHint(model, kind: currentActive.kind),
                                isSelected: model == currentActive.modelID
                            ) {
                                appState.selectAIModel(model, for: currentActive.id)
                                dismiss()
                            }
                        }

                        if !trimmedQuery.isEmpty && !currentActive.availableModels.contains(where: { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
                            AIModelPopoverRow(
                                modelID: trimmedQuery,
                                hint: "Use custom model ID",
                                isSelected: false,
                                isCustomEntry: true
                            ) {
                                appState.selectAIModel(trimmedQuery, for: currentActive.id)
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func ollamaPopoverModelSection(for profile: AIProviderProfile) -> some View {
        switch appState.ollamaStatus {
        case .unknown:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Checking Local Ollama…")
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.app")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.warning)
                    Text("Ollama isn't installed yet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                }
                Text("Install Ollama in 1 click (Homebrew or .dmg) to run private local coding models.")
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    dismiss()
                    appState.openAIProviderSettings(selecting: profile.id)
                } label: {
                    Text("Set Up Local Ollama…")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6.5)
                        .background(CeptraTheme.accent, in: RoundedRectangle(cornerRadius: 7.5, style: .continuous))
                }
                .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.975))
            }
            .padding(10)
            .background(CeptraTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(CeptraTheme.warning.opacity(0.24), lineWidth: 0.75))
            .padding(.horizontal, 4)

        case .installedNotRunning:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CeptraTheme.warning)
                    Text("Ollama server is stopped")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                }
                Text("Start your local Ollama daemon to load installed models.")
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textSecondary)
                Button {
                    Task { await appState.startLocalOllama() }
                } label: {
                    HStack(spacing: 6) {
                        if appState.isStartingOllama {
                            ProgressView().controlSize(.mini).scaleEffect(0.75)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 9.5))
                        }
                        Text(appState.isStartingOllama ? "Starting Ollama…" : "Start Ollama")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6.5)
                    .background(CeptraTheme.accent, in: RoundedRectangle(cornerRadius: 7.5, style: .continuous))
                }
                .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.975))
                .disabled(appState.isStartingOllama)
            }
            .padding(10)
            .background(CeptraTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(CeptraTheme.warning.opacity(0.24), lineWidth: 0.75))
            .padding(.horizontal, 4)

        case .runningNoModels:
            VStack(alignment: .leading, spacing: 7) {
                Text("No local models downloaded yet")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)

                if let pull = appState.ollamaPullProgress {
                    ollamaPopoverPullProgress(pull)
                } else {
                    Button {
                        appState.pullOllamaModel("qwen2.5-coder:7b", for: profile)
                    } label: {
                        Label("Install qwen2.5-coder:7b (~4.7 GB)", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(CeptraTheme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.975))

                    Button {
                        dismiss()
                        appState.openAIProviderSettings(selecting: profile.id)
                    } label: {
                        Text("Browse Recommended Models…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CeptraTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5.5)
                            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(9)
            .background(CeptraTheme.hoverBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 0.75))
            .padding(.horizontal, 4)

        case .running(let models):
            VStack(spacing: 2) {
                if let pull = appState.ollamaPullProgress {
                    ollamaPopoverPullProgress(pull)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                }

                ForEach(models) { model in
                    AIModelPopoverRow(
                        modelID: model.name,
                        hint: model.compactDetails.isEmpty ? modelCapabilityHint(model.name, kind: .ollama) : model.compactDetails,
                        isSelected: model.name == profile.modelID
                    ) {
                        appState.selectAIModel(model.name, for: profile.id)
                        dismiss()
                    }
                }

                Rectangle()
                    .fill(CeptraTheme.border)
                    .frame(height: 0.75)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)

                AIQuickActionPopoverRow(
                    title: "Install More Local Models…",
                    trailingBadge: nil,
                    trailingColor: CeptraTheme.accent,
                    systemImage: "arrow.down.circle",
                    iconColor: CeptraTheme.accent
                ) {
                    dismiss()
                    appState.openAIProviderSettings(selecting: profile.id)
                }
            }

        case .remoteUnreachable(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("Remote Ollama Unreachable")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.failure)
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .lineLimit(2)
                Button {
                    dismiss()
                    appState.openAIProviderSettings(selecting: profile.id)
                } label: {
                    Text("Configure Endpoint…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CeptraTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(9)
            .background(CeptraTheme.failure.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 4)
        }
    }

    private func ollamaPopoverPullProgress(_ pull: OllamaPullProgress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(pull.modelName)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if let pct = pull.percentageText {
                    Text(pct)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.accent)
                }
                Button("Cancel") {
                    appState.cancelOllamaModelPull()
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CeptraTheme.failure)
                .buttonStyle(.plain)
            }
            if let f = pull.fraction {
                ProgressView(value: f).tint(CeptraTheme.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(CeptraTheme.accent)
            }
            Text(pull.byteProgressText ?? pull.status)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(CeptraTheme.textMuted)
        }
    }

    private func modelCapabilityHint(_ model: String, kind: AIProviderKind) -> String? {
        let lower = model.lowercased()
        if lower == "default" {
            return kind.isCLI ? "Uses CLI default configuration" : "Server default model"
        }
        if lower.contains("opus") { return "Deep reasoning & complex refactors" }
        if lower.contains("sonnet") { return "Balanced speed & coding accuracy" }
        if lower.contains("haiku") { return "Fast & lightweight quick edits" }
        if lower.contains("flash") { return "Fast, low-latency responses" }
        if lower.contains("2.5-pro") || lower.hasSuffix("-pro") { return "Complex multi-step reasoning" }
        if lower.contains("o4-mini") || lower.contains("o3-mini") { return "Fast reasoning model" }
        if lower.contains("mini") { return "Fast & cost-efficient" }
        if lower.contains("gpt-4.1") { return "High-precision coding & instruction following" }
        if lower.contains("gpt-4o") { return "Versatile multimodal flagship" }
        if lower.contains("coder") || lower.contains("codellama") { return "Code-specialized local model" }
        return nil
    }
}

private struct AIProviderPopoverRow: View {
    let profile: AIProviderProfile
    let subtitleOverride: String?
    let isSelected: Bool
    let tint: Color
    let badgeText: String?
    let badgeColor: Color
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: profile.kind.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(isSelected ? 0.18 : 0.11), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tint.opacity(isSelected ? 0.35 : 0.15), lineWidth: 0.75)
                    )

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 5) {
                        Text(profile.shortDisplayTitle)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(CeptraTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let badgeText {
                            Text(badgeText)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(badgeColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(badgeColor.opacity(0.12), in: Capsule())
                        }
                    }

                    Text(subtitleOverride ?? (profile.modelID.isEmpty ? (badgeText ?? "Setup needed") : profile.modelID))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(isHovered || isSelected ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.accent)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.75).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(CeptraTheme.accent.opacity(isHovered ? 0.16 : 0.11))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                .strokeBorder(CeptraTheme.accent.opacity(0.32), lineWidth: 0.75)
                        )
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(CeptraTheme.hoverBG)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                .strokeBorder(CeptraTheme.borderStrong, lineWidth: 0.65)
                        )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.985))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isSelected)
        .onHover { isHovered = $0 }
    }
}

private struct AIModelPopoverRow: View {
    let modelID: String
    let hint: String?
    let isSelected: Bool
    var isCustomEntry: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if isCustomEntry {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(CeptraTheme.accent)
                    } else if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(CeptraTheme.accent)
                    } else {
                        Circle()
                            .fill(isHovered ? CeptraTheme.textSecondary : CeptraTheme.textMuted.opacity(0.45))
                            .frame(width: 4.5, height: 4.5)
                    }
                }
                .frame(width: 14, alignment: .center)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(modelID)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? CeptraTheme.textPrimary : (isHovered ? CeptraTheme.textPrimary : CeptraTheme.textPrimary.opacity(0.9)))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let hint, !hint.isEmpty {
                        Text(hint)
                            .font(.system(size: 10))
                            .foregroundStyle(isHovered || isSelected ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if isSelected {
                    Text("Active")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CeptraTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(CeptraTheme.accent.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, hint == nil ? 5.5 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? CeptraTheme.accent.opacity(0.16) : CeptraTheme.hoverBG)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(isSelected ? CeptraTheme.accent.opacity(0.32) : CeptraTheme.border, lineWidth: 0.65)
                        )
                } else if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(CeptraTheme.accent.opacity(0.10))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.985))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct AIQuickActionPopoverRow: View {
    let title: String
    let trailingBadge: String?
    let trailingColor: Color
    let systemImage: String
    let iconColor: Color
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovered ? CeptraTheme.textPrimary : iconColor)
                    .frame(width: 16, alignment: .center)

                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let trailingBadge, !trailingBadge.isEmpty {
                    Text(trailingBadge)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(trailingColor)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(CeptraTheme.hoverBG, in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(CeptraTheme.hoverBG)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(CeptraTheme.border, lineWidth: 0.65)
                        )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.985))
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct AIHeaderIconButtonChrome: View {
    let systemImage: String
    var isActive: Bool = false

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(isActive ? CeptraTheme.accent : (isHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary))
            .frame(width: 28, height: 28)
            .background(
                (isActive ? CeptraTheme.accent.opacity(0.14) : (isHovered ? CeptraTheme.hoverBG : Color.clear)),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isActive ? CeptraTheme.accent.opacity(0.32) : (isHovered ? CeptraTheme.border : Color.clear), lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
            .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isActive)
            .onHover { isHovered = $0 }
    }
}

private struct AIHeaderIconButton: View {
    let systemImage: String
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AIHeaderIconButtonChrome(systemImage: systemImage)
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.94))
        .help(helpText)
    }
}

private struct AIThreadTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AIThreadBottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AIThreadJumpButton: View {
    let icon: String
    let label: String?
    let showPulseDot: Bool
    let helpText: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                if showPulseDot {
                    Circle()
                        .fill(CeptraTheme.accent)
                        .frame(width: 5.5, height: 5.5)
                }
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                if let label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 10.5, weight: .semibold))
                }
            }
            .foregroundStyle(isHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
            .padding(.horizontal, label == nil ? 8 : 9.5)
            .frame(height: 26)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(isHovered ? CeptraTheme.elevatedBG.opacity(0.88) : CeptraTheme.panelBG.opacity(0.82))
                    )
            }
            .overlay(
                Capsule()
                    .strokeBorder(isHovered ? CeptraTheme.accent.opacity(0.55) : CeptraTheme.borderStrong, lineWidth: 0.85)
            )
            .shadow(color: Color.black.opacity(0.24), radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.94))
        .help(helpText)
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Recent Chats History & Deletion Popover

private struct AIRecentChatsPopoverContent: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.ceptraDropdownDismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchQuery: String = ""
    @State private var confirmingClearAll: Bool = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt
    }()

    private var visibleSessions: [AIChatSession] {
        // Show saved conversations plus the active draft only if there are no saved chats yet
        let saved = appState.savedAISessions
        let base = saved.isEmpty ? appState.aiSessions : saved
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(base.prefix(20)) }
        return base.filter { session in
            session.title.localizedCaseInsensitiveContains(q)
                || session.messages.contains(where: { $0.content.localizedCaseInsensitiveContains(q) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header + Quick "+ New" Button
            HStack(spacing: 6) {
                Text("RECENT CHATS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(CeptraTheme.textMuted)

                if !appState.savedAISessions.isEmpty {
                    Text("\(appState.savedAISessions.count)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(CeptraTheme.hoverBG, in: Capsule())
                }

                Spacer()

                Button {
                    appState.startNewAIChat()
                    dismiss()
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text("New")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(CeptraTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(CeptraTheme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.95))
                .help("Start New Chat")
            }
            .padding(.horizontal, 9)
            .padding(.top, 4)
            .padding(.bottom, 2)

            if appState.savedAISessions.count > 4 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(CeptraTheme.textMuted)
                    TextField("Search conversations…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(CeptraTheme.canvasBG.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 0.75))
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            }

            if visibleSessions.isEmpty {
                Text(searchQuery.isEmpty ? "No saved conversations yet" : "No matching conversations")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 2) {
                    ForEach(visibleSessions) { session in
                        let isCurrent = session.id == appState.activeAISession?.id
                        let relTime = Self.relativeFormatter.localizedString(for: session.updatedAt, relativeTo: Date())
                        let msgLabel = "\(session.messages.count) msg\(session.messages.count == 1 ? "" : "s") · \(relTime)"

                        AIRecentChatRow(
                            title: session.title,
                            subtitle: msgLabel,
                            isSelected: isCurrent,
                            canDelete: !session.messages.isEmpty || appState.aiSessions.count > 1,
                            onSelect: {
                                appState.selectAISession(id: session.id)
                                dismiss()
                            },
                            onDelete: {
                                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                                    appState.deleteAISession(id: session.id)
                                }
                                if appState.savedAISessions.isEmpty {
                                    dismiss()
                                }
                            }
                        )
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                    }
                }
            }

            if !appState.savedAISessions.isEmpty {
                Rectangle()
                    .fill(CeptraTheme.border)
                    .frame(height: 0.75)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)

                if confirmingClearAll {
                    HStack(spacing: 6) {
                        Text("Clear \(appState.savedAISessions.count) chat\(appState.savedAISessions.count == 1 ? "" : "s")?")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CeptraTheme.failure)
                        Spacer()
                        Button("Cancel") {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                                confirmingClearAll = false
                            }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(CeptraTheme.hoverBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .buttonStyle(.plain)

                        Button("Clear All") {
                            appState.deleteAllAISessions()
                            confirmingClearAll = false
                            dismiss()
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(CeptraTheme.failure, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.96))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(CeptraTheme.failure.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .transition(.opacity)
                } else {
                    AIQuickActionPopoverRow(
                        title: "Clear All Conversations…",
                        trailingBadge: nil,
                        trailingColor: CeptraTheme.failure,
                        systemImage: "trash",
                        iconColor: CeptraTheme.failure.opacity(0.85)
                    ) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                            confirmingClearAll = true
                        }
                    }
                }
            }
        }
    }
}

private struct AIRecentChatRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isTrashHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isSelected ? CeptraTheme.accent : (isHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary))
                        .frame(width: 16, alignment: .center)

                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(CeptraTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(subtitle)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(isHovered || isSelected ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected && !isHovered {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accent)
                    .frame(width: 22, height: 22)
            } else if canDelete && isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(isTrashHovered ? CeptraTheme.failure : CeptraTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(
                            isTrashHovered ? CeptraTheme.failure.opacity(0.14) : CeptraTheme.canvasBG.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.92))
                .onHover { isTrashHovered = $0 }
                .help("Delete conversation")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(isSelected ? CeptraTheme.accent.opacity(0.15) : CeptraTheme.hoverBG)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .strokeBorder(isSelected ? CeptraTheme.accent.opacity(0.32) : CeptraTheme.borderStrong, lineWidth: 0.65)
                    )
            } else if isSelected {
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(CeptraTheme.accent.opacity(0.11))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isTrashHovered)
        .onHover { hovering in
            isHovered = hovering
            if !hovering { isTrashHovered = false }
        }
    }
}

private struct AIInlineRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var spinAngle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9.5, weight: .semibold))
                    .rotationEffect(.degrees(spinAngle))
                Text("Refresh")
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(isRefreshing ? CeptraTheme.accent : (isHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                (isRefreshing ? CeptraTheme.accent.opacity(0.12) : (isHovered ? CeptraTheme.activeBG : CeptraTheme.hoverBG)),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(isRefreshing ? CeptraTheme.accent.opacity(0.32) : (isHovered ? CeptraTheme.borderStrong : Color.clear), lineWidth: 0.65)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.95))
        .disabled(isRefreshing)
        .onHover { isHovered = $0 }
        .onChange(of: isRefreshing) { _, refreshing in
            guard !reduceMotion else { return }
            if refreshing {
                withAnimation(.linear(duration: 0.75).repeatForever(autoreverses: false)) {
                    spinAngle += 360
                }
            } else {
                withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                    spinAngle = 0
                }
            }
        }
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
    }
}

// MARK: - Hover-Polished Starter Action Card

private struct AIStarterActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    var trailingIcon: String = "arrow.up.right"
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(isHovered ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(tint.opacity(isHovered ? 0.32 : 0.12), lineWidth: 0.75)
                    )

                VStack(alignment: .leading, spacing: 2.5) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(isHovered ? CeptraTheme.textPrimary.opacity(0.78) : CeptraTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 6)

                Image(systemName: trailingIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovered ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                    .offset(x: isHovered && !reduceMotion ? 1.5 : 0, y: isHovered && trailingIcon == "arrow.up.right" && !reduceMotion ? -1 : 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                isHovered ? CeptraTheme.elevatedBG.opacity(0.65) : CeptraTheme.canvasBG,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isHovered ? CeptraTheme.borderStrong : CeptraTheme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.985))
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Context Attachment Toggle Pill

private struct AIContextPillButton: View {
    let item: AIContextAttachment
    let isOn: Bool
    let formattedSize: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 12, weight: .medium))
                Text(item.kind.shortLabel)
                    .font(.system(size: 12.5, weight: isOn ? .semibold : .medium))
                Text(formattedSize)
                    .font(.system(size: 10.5, design: .monospaced))
                    .opacity(0.82)
                if isOn && item.wasRedacted {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CeptraTheme.success)
                }
            }
            .foregroundStyle(isOn ? CeptraTheme.accent : (isHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary))
            .padding(.horizontal, 9.5)
            .padding(.vertical, 5)
            .background(
                isOn
                    ? CeptraTheme.accent.opacity(isHovered ? 0.18 : 0.12)
                    : (isHovered ? CeptraTheme.hoverBG : CeptraTheme.panelBG.opacity(0.7)),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isOn
                        ? CeptraTheme.accent.opacity(isHovered ? 0.55 : 0.38)
                        : (isHovered ? CeptraTheme.borderStrong : CeptraTheme.border),
                    lineWidth: 0.75
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.96))
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
        .help("\(isOn ? "Attached" : "Excluded"): \(item.label) (\(formattedSize))\(item.wasRedacted ? " · Secrets redacted" : "")")
    }
}

// MARK: - AI Permission Mode Popover

private struct AIPermissionModePopoverContent: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.ceptraDropdownDismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("AI PERMISSIONS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(CeptraTheme.textMuted)
                Spacer()
                Text(appState.aiPermissionMode.shortLabel)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint(for: appState.aiPermissionMode))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(tint(for: appState.aiPermissionMode).opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 9)
            .padding(.top, 4)
            .padding(.bottom, 2)

            VStack(spacing: 3) {
                ForEach(AIPermissionMode.allCases) { mode in
                    let isSelected = appState.aiPermissionMode == mode
                    let color = tint(for: mode)
                    Button {
                        appState.setAIPermissionMode(mode)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: mode.symbolName)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(color)
                                .frame(width: 24, height: 24)
                                .background(color.opacity(isSelected ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(mode.displayName)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                        .foregroundStyle(CeptraTheme.textPrimary)
                                    if mode == .askToProceed {
                                        Text("Default")
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .foregroundStyle(CeptraTheme.textMuted)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(CeptraTheme.hoverBG, in: Capsule())
                                    }
                                }
                                Text(mode.summary)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(CeptraTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer(minLength: 4)

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(color)
                                    .padding(.top, 2)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            isSelected ? color.opacity(0.10) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isSelected ? color.opacity(0.35) : Color.clear, lineWidth: 0.75)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Rectangle()
                .fill(CeptraTheme.border)
                .frame(height: 0.75)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(CeptraTheme.success)
                    .padding(.top, 1)
                Text("Always protected in all modes: ~/.ssh, ~/.aws, Keychain, .env files, host env secrets, and paths outside your project workspace are strictly blocked.")
                    .font(.system(size: 10))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 4)
        }
    }

    private func tint(for mode: AIPermissionMode) -> Color {
        switch mode {
        case .readOnly: return CeptraTheme.cyan
        case .askToProceed: return CeptraTheme.accent
        case .fullWorkspace: return CeptraTheme.accentWarm
        }
    }
}

// MARK: - Media & File Attachment Popover, Pending Cards & Preview Sheet

private struct AIPreviewImageItem: Identifiable {
    let id = UUID()
    let title: String
    let image: NSImage
}

private struct AIMediaPreviewSheet: View {
    let item: AIPreviewImageItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CeptraTheme.accent)
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(CeptraTheme.panelBG)

            Divider().overlay(CeptraTheme.border)

            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: item.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 780, maxHeight: 540)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(16)
            }
            .frame(minWidth: 480, maxWidth: 820, minHeight: 340, maxHeight: 580)
            .background(CeptraTheme.canvasBG)
        }
    }
}

private struct AIAttachMediaPopoverContent: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.ceptraDropdownDismiss) private var dismiss

    private var clipboardHasImageOrFile: Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return true
        }
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("ATTACH TO PROMPT")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.65)
                .foregroundStyle(CeptraTheme.textMuted)
                .padding(.horizontal, 9)
                .padding(.top, 4)
                .padding(.bottom, 2)

            AIQuickActionPopoverRow(
                title: "Files, Images, PDF or Video…",
                trailingBadge: "Browse",
                trailingColor: CeptraTheme.accent,
                systemImage: "folder.badge.plus",
                iconColor: CeptraTheme.accent
            ) {
                dismiss()
                DispatchQueue.main.async {
                    appState.presentAIFileAttachmentPanel()
                }
            }

            AIQuickActionPopoverRow(
                title: "Paste from Clipboard",
                trailingBadge: clipboardHasImageOrFile ? "Ready · ⌘V" : "⌘V",
                trailingColor: clipboardHasImageOrFile ? CeptraTheme.success : CeptraTheme.textMuted,
                systemImage: "doc.on.clipboard",
                iconColor: clipboardHasImageOrFile ? CeptraTheme.success : CeptraTheme.textSecondary
            ) {
                dismiss()
                _ = appState.pasteFromClipboardIntoAIAttachments()
            }

            if let latestShot = appState.latestWorkspaceScreenshotURL {
                AIQuickActionPopoverRow(
                    title: "Latest Failure Screenshot",
                    trailingBadge: String(latestShot.lastPathComponent.prefix(16)),
                    trailingColor: CeptraTheme.warning,
                    systemImage: "camera.viewfinder",
                    iconColor: CeptraTheme.warning
                ) {
                    dismiss()
                    appState.attachLatestWorkspaceScreenshot()
                }
            }

            let workspaceFiles = Array(appState.quickPickWorkspaceFileURLs.prefix(6))
            if !workspaceFiles.isEmpty {
                Rectangle()
                    .fill(CeptraTheme.border)
                    .frame(height: 0.75)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)

                Text("WORKSPACE FILES")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(CeptraTheme.textMuted)
                    .padding(.horizontal, 9)
                    .padding(.top, 2)
                    .padding(.bottom, 2)

                ForEach(workspaceFiles, id: \.path) { url in
                    let isAlreadyAttached = appState.aiPendingAttachments.contains(where: { $0.filePath == url.standardizedFileURL.path })
                    AIQuickActionPopoverRow(
                        title: url.lastPathComponent,
                        trailingBadge: isAlreadyAttached ? "Added" : relativeFolderHint(for: url),
                        trailingColor: isAlreadyAttached ? CeptraTheme.success : CeptraTheme.textMuted,
                        systemImage: isAlreadyAttached ? "checkmark.circle.fill" : "doc.text",
                        iconColor: isAlreadyAttached ? CeptraTheme.success : CeptraTheme.textSecondary
                    ) {
                        dismiss()
                        appState.addAIAttachments(from: [url])
                    }
                }
            }

            Rectangle()
                .fill(CeptraTheme.border)
                .frame(height: 0.75)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)

            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(CeptraTheme.textMuted)
                Text("Drag & drop files or press ⌘V to paste screenshots (up to \(AIMediaAttachmentProcessor.maxAttachmentsPerMessage) items)")
                    .font(.system(size: 10))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
        }
    }

    private func relativeFolderHint(for url: URL) -> String? {
        guard let root = appState.workspace?.rootURL.standardizedFileURL.path else { return nil }
        let dir = url.deletingLastPathComponent().standardizedFileURL.path
        if dir == root { return "root" }
        if dir.hasPrefix(root + "/") {
            return String(dir.dropFirst(root.count + 1))
        }
        return nil
    }
}

private struct AIPendingAttachmentCard: View {
    let attachment: AIUserAttachment
    let onPreview: (NSImage) -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    private var thumbnailImage: NSImage? {
        guard let b64 = attachment.thumbnailBase64,
              let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    private var fullPreviewImage: NSImage? {
        if let first = attachment.images.first,
           let data = Data(base64Encoded: first.base64Data),
           let full = NSImage(data: data) {
            return full
        }
        return thumbnailImage
    }

    private var kindTint: Color {
        switch attachment.kind {
        case .image: return CeptraTheme.accent
        case .pdf: return CeptraTheme.failure
        case .video: return CeptraTheme.violet
        case .textFile: return CeptraTheme.cyan
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumb = thumbnailImage {
                    Button {
                        if let img = fullPreviewImage { onPreview(img) }
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(nsImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                            if attachment.kind == .video || attachment.kind == .pdf {
                                Image(systemName: attachment.kind == .video ? "play.fill" : "doc.richtext.fill")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(Color.black.opacity(0.68), in: Circle())
                                    .padding(2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Click to preview \(attachment.displayName)")
                } else {
                    Image(systemName: attachment.kind.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(kindTint)
                        .frame(width: 36, height: 36)
                        .background(kindTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(attachment.displayName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if attachment.wasRedacted {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(CeptraTheme.success)
                            .help("Sensitive values redacted before sending")
                    }
                }
                Text(attachment.subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: 132, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isHovered ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                    .frame(width: 18, height: 18)
                    .background(CeptraTheme.hoverBG, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Remove \(attachment.displayName)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(CeptraTheme.panelBG.opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHovered ? CeptraTheme.borderStrong : CeptraTheme.border, lineWidth: 0.75)
        )
        .onHover { isHovered = $0 }
    }
}

private struct AISentThumbnailButton: View {
    let item: AIAttachedContextSummary
    let onPreview: (NSImage) -> Void

    private var thumb: NSImage? {
        guard let b64 = item.thumbnailBase64,
              let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        if let thumb {
            Button {
                onPreview(thumb)
            } label: {
                ZStack(alignment: .bottomLeading) {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(CeptraTheme.borderStrong, lineWidth: 0.75)
                        )

                    if item.kind == .userVideo || item.kind == .userPDF {
                        Image(systemName: item.kind.symbolName)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(3.5)
                            .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(3)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("\(item.label) — Click to preview")
        }
    }
}

// MARK: - Slash Command Autocomplete Panel, Quick Skills Popover & Full Skills Manager Sheet

private struct AISlashAutocompletePanel: View {
    let matches: [AISkillDescriptor]
    let selectedIndex: Int
    let onSelect: (AISkillDescriptor) -> Void
    let onOpenManager: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "slash.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CeptraTheme.violet)
                Text("COMMANDS & SKILLS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(CeptraTheme.textMuted)
                Spacer()
                Text("↑↓ · ↩/⇥ · Esc")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(CeptraTheme.panelBG.opacity(0.85))

            Divider().overlay(CeptraTheme.border)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 2) {
                        ForEach(Array(matches.prefix(24).enumerated()), id: \.element.id) { idx, skill in
                            let isSelected = idx == selectedIndex
                            Button {
                                onSelect(skill)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: skill.symbolName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(sourceTint(for: skill.source))
                                        .frame(width: 22, height: 22)
                                        .background(
                                            sourceTint(for: skill.source).opacity(isSelected ? 0.18 : 0.10),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        )

                                    VStack(alignment: .leading, spacing: 1.5) {
                                        HStack(spacing: 5) {
                                            Text(skill.slashCommand)
                                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                                .foregroundStyle(CeptraTheme.textPrimary)
                                            if let hint = skill.argumentHint, !hint.isEmpty {
                                                Text(hint)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(CeptraTheme.textMuted)
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                        }
                                        Text(skill.description)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(isSelected ? CeptraTheme.textPrimary.opacity(0.85) : CeptraTheme.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }

                                    Spacer(minLength: 4)

                                    Text(skill.source.badgeLabel)
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(sourceTint(for: skill.source))
                                        .padding(.horizontal, 5.5)
                                        .padding(.vertical, 1.5)
                                        .background(sourceTint(for: skill.source).opacity(0.12), in: Capsule())
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    isSelected ? CeptraTheme.accent.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(isSelected ? CeptraTheme.accent.opacity(0.38) : Color.clear, lineWidth: 0.75)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .id(skill.id)
                        }
                    }
                    .padding(5)
                }
                .frame(maxHeight: min(230, CGFloat(min(matches.count, 6)) * 42 + 12))
                .onChange(of: selectedIndex) { _, nextIdx in
                    if nextIdx >= 0 && nextIdx < matches.count {
                        proxy.scrollTo(matches[nextIdx].id, anchor: .center)
                    }
                }
            }

            Divider().overlay(CeptraTheme.border)

            Button(action: onOpenManager) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Browse All Skills or Create Project SKILL.md…")
                        .font(.system(size: 10.5, weight: .medium))
                    Spacer()
                    Text("/skills")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .foregroundStyle(CeptraTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(CeptraTheme.panelBG.opacity(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(CeptraTheme.borderStrong, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 14, y: -3)
    }

    private func sourceTint(for source: AISkillSource) -> Color {
        switch source {
        case .workspace: return CeptraTheme.success
        case .builtIn: return CeptraTheme.accent
        case .userGlobal: return CeptraTheme.violet
        }
    }
}

private struct AISkillsQuickPopoverContent: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.ceptraDropdownDismiss) private var dismiss

    @State private var searchText: String = ""

    private var filtered: [AISkillDescriptor] {
        let invocable = appState.aiAvailableSkills.filter { !$0.isMetaBrowseCommand }
        return AISkillRegistry.filterSkills(invocable, query: searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("COMMANDS & AGENT SKILLS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(CeptraTheme.textMuted)
                Spacer()
                Button {
                    appState.refreshAISkills()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Rescan workspace & global SKILL.md files")
            }
            .padding(.horizontal, 9)
            .padding(.top, 4)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(CeptraTheme.textMuted)
                TextField("Filter /commands or skills…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textPrimary)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(CeptraTheme.canvasBG.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 0.75))
            .padding(.horizontal, 6)
            .padding(.bottom, 2)

            if filtered.isEmpty {
                Text("No matching skills found")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach([AISkillSource.workspace, .builtIn, .userGlobal], id: \.self) { source in
                    let group = filtered.filter { $0.source == source }
                    if !group.isEmpty {
                        Text(source.sectionTitle)
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(CeptraTheme.textMuted)
                            .padding(.horizontal, 9)
                            .padding(.top, 4)

                        ForEach(group) { skill in
                            let isPinned = appState.aiPinnedSkill?.id == skill.id
                            Button {
                                appState.selectAISkill(skill)
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: skill.symbolName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(sourceTint(for: skill.source))
                                        .frame(width: 20, height: 20)
                                        .background(sourceTint(for: skill.source).opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                                    VStack(alignment: .leading, spacing: 1.5) {
                                        Text(skill.slashCommand)
                                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(CeptraTheme.textPrimary)
                                        Text(skill.description)
                                            .font(.system(size: 10))
                                            .foregroundStyle(CeptraTheme.textSecondary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }

                                    Spacer(minLength: 4)

                                    if isPinned {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(CeptraTheme.violet)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5.5)
                                .background(
                                    isPinned ? CeptraTheme.violet.opacity(0.10) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Rectangle()
                .fill(CeptraTheme.border)
                .frame(height: 0.75)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)

            AIQuickActionPopoverRow(
                title: "Manage Skills / Create SKILL.md…",
                trailingBadge: "/skills",
                trailingColor: CeptraTheme.violet,
                systemImage: "plus.rectangle.on.folder",
                iconColor: CeptraTheme.violet
            ) {
                dismiss()
                DispatchQueue.main.async {
                    appState.showingAISkillsSheet = true
                }
            }
        }
    }

    private func sourceTint(for source: AISkillSource) -> Color {
        switch source {
        case .workspace: return CeptraTheme.success
        case .builtIn: return CeptraTheme.accent
        case .userGlobal: return CeptraTheme.violet
        }
    }
}

private struct AISkillsBrowserSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var newSkillSlug: String = ""
    @State private var newSkillDesc: String = ""
    @State private var newSkillIsGlobal: Bool = false

    private var invocableSkills: [AISkillDescriptor] {
        let base = appState.aiAvailableSkills.filter { !$0.isMetaBrowseCommand }
        return AISkillRegistry.filterSkills(base, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "slash.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CeptraTheme.violet)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("Slash Commands & Agent Skills (`SKILL.md`)")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Text("Works identically on Local Ollama, Cloud APIs, and CLI Agents")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                Spacer()
                Button {
                    appState.refreshAISkills()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(CeptraTheme.panelBG)

            Divider().overlay(CeptraTheme.border)

            VStack(spacing: 12) {
                // Search + Global Discovery Toggle
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.textMuted)
                        TextField("Search built-in commands, project skills, or global SKILL.md…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))

                    Toggle(
                        "Global Skills",
                        isOn: Binding(
                            get: { appState.settings.aiSettings.enableGlobalAgentSkills },
                            set: { appState.setEnableGlobalAgentSkills($0) }
                        )
                    )
                    .font(.system(size: 11.5))
                    .help("Discover read-only SKILL.md files in ~/.ceptra, ~/.agents, ~/.claude, and ~/.codex")
                }

                // Discovered Skills List
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach([AISkillSource.workspace, .builtIn, .userGlobal], id: \.self) { source in
                            let group = invocableSkills.filter { $0.source == source }
                            if !group.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(source.sectionTitle) (\(group.count))")
                                        .font(.system(size: 10, weight: .semibold))
                                        .tracking(0.65)
                                        .foregroundStyle(CeptraTheme.textMuted)

                                    ForEach(group) { skill in
                                        HStack(alignment: .top, spacing: 10) {
                                            Image(systemName: skill.symbolName)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(sourceTint(for: skill.source))
                                                .frame(width: 26, height: 26)
                                                .background(sourceTint(for: skill.source).opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                                            VStack(alignment: .leading, spacing: 2.5) {
                                                HStack(spacing: 6) {
                                                    Text(skill.slashCommand)
                                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                        .foregroundStyle(CeptraTheme.textPrimary)
                                                    if let hint = skill.argumentHint, !hint.isEmpty {
                                                        Text(hint)
                                                            .font(.system(size: 10.5, design: .monospaced))
                                                            .foregroundStyle(CeptraTheme.textMuted)
                                                    }
                                                    Text(skill.sourceOriginLabel)
                                                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                                        .foregroundStyle(sourceTint(for: skill.source))
                                                        .padding(.horizontal, 5.5)
                                                        .padding(.vertical, 1)
                                                        .background(sourceTint(for: skill.source).opacity(0.12), in: Capsule())
                                                }

                                                Text(skill.description)
                                                    .font(.system(size: 11.5))
                                                    .foregroundStyle(CeptraTheme.textSecondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }

                                            Spacer(minLength: 8)

                                            HStack(spacing: 6) {
                                                if let path = skill.filePath {
                                                    Button("Edit") {
                                                        appState.openFileByURL(URL(fileURLWithPath: path))
                                                        dismiss()
                                                    }
                                                    .controlSize(.small)
                                                }
                                                Button("Use") {
                                                    appState.selectAISkill(skill)
                                                    dismiss()
                                                }
                                                .buttonStyle(.borderedProminent)
                                                .controlSize(.small)
                                            }
                                        }
                                        .padding(10)
                                        .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                Divider().overlay(CeptraTheme.border)

                // 1-Click Portable Skill Creator
                VStack(alignment: .leading, spacing: 8) {
                    Text("CREATE NEW SKILL (`SKILL.md`)")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.65)
                        .foregroundStyle(CeptraTheme.textMuted)

                    HStack(spacing: 8) {
                        TextField("slug (e.g. locator-audit)", text: $newSkillSlug)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 185)

                        TextField("Short description of what this skill does…", text: $newSkillDesc)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))

                        Picker("", selection: $newSkillIsGlobal) {
                            Text("Project (.ceptra)").tag(false)
                            Text("Personal (~/.ceptra)").tag(true)
                        }
                        .labelsHidden()
                        .frame(width: 148)

                        Button("Create & Open") {
                            if appState.createAndOpenAISkill(
                                slug: newSkillSlug,
                                description: newSkillDesc,
                                global: newSkillIsGlobal
                            ) {
                                newSkillSlug = ""
                                newSkillDesc = ""
                                dismiss()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(AISkillRegistry.sanitizeSlug(newSkillSlug).isEmpty)
                    }
                }
            }
            .padding(16)
            .background(CeptraTheme.sidebarBG)
        }
        .frame(minWidth: 680, minHeight: 500)
        .onAppear {
            appState.refreshAISkills()
            if appState.workspace == nil {
                newSkillIsGlobal = true
            }
        }
    }

    private func sourceTint(for source: AISkillSource) -> Color {
        switch source {
        case .workspace: return CeptraTheme.success
        case .builtIn: return CeptraTheme.accent
        case .userGlobal: return CeptraTheme.violet
        }
    }
}

// MARK: - Native Auto-Growing Multi-line Prompt Editor (↩ Send · ⇧↩ New line · ⌘V Paste Media · / Skills)

private struct AIComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    var minHeight: CGFloat = 48
    var maxHeight: CGFloat = 156
    var isSlashMenuOpen: Bool = false
    var onSubmit: () -> Void
    var onFocusChanged: (Bool) -> Void
    var onPasteImage: (NSImage) -> Void
    var onPasteFileURLs: ([URL]) -> Void
    var onSlashMoveUp: () -> Void = {}
    var onSlashMoveDown: () -> Void = {}
    var onSlashConfirm: () -> Void = {}
    var onSlashDismiss: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]

        textView.string = text
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.onFocusChanged = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onFocusChanged(focused)
        }
        textView.onLayoutChange = { [weak coordinator = context.coordinator] in
            coordinator?.recalculateHeight(for: textView)
        }
        textView.onPasteImage = { [weak coordinator = context.coordinator] image in
            coordinator?.parent.onPasteImage(image)
        }
        textView.onPasteFileURLs = { [weak coordinator = context.coordinator] urls in
            coordinator?.parent.onPasteFileURLs(urls)
        }
        textView.isSlashMenuOpenProvider = { [weak coordinator = context.coordinator] in
            coordinator?.parent.isSlashMenuOpen ?? false
        }
        textView.onSlashMoveUp = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSlashMoveUp()
        }
        textView.onSlashMoveDown = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSlashMoveDown()
        }
        textView.onSlashConfirm = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSlashConfirm()
        }
        textView.onSlashDismiss = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSlashDismiss()
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.recalculateHeight(for: textView)
        return scrollView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: max(0, proposal.width ?? 240), height: measuredHeight)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text && !textView.hasMarkedText() {
            textView.string = text
            context.coordinator.recalculateHeight(for: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIComposerTextView
        weak var textView: ComposerNSTextView?

        init(_ parent: AIComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? ComposerNSTextView else { return }
            let updated = tv.string
            if parent.text != updated {
                parent.text = updated
            }
            recalculateHeight(for: tv)
        }

        func recalculateHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer).height
            let insetY = textView.textContainerInset.height * 2
            let desired = min(max(ceil(used + insetY + 4), parent.minHeight), parent.maxHeight)
            if abs(parent.measuredHeight - desired) > 0.5 {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.parent.measuredHeight = desired
                }
            }
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onLayoutChange: (() -> Void)?
    var onPasteImage: ((NSImage) -> Void)?
    var onPasteFileURLs: (([URL]) -> Void)?
    var isSlashMenuOpenProvider: (() -> Bool)?
    var onSlashMoveUp: (() -> Void)?
    var onSlashMoveDown: (() -> Void)?
    var onSlashConfirm: (() -> Void)?
    var onSlashDismiss: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChanged?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChanged?(false) }
        return ok
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.size.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            onLayoutChange?()
        }
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            onPasteFileURLs?(urls)
            return
        }

        let hasPlainText = !(pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasImageType = pb.types?.contains(where: { $0 == .png || $0 == .tiff }) ?? false
        if !hasPlainText && hasImageType, let image = NSImage(pasteboard: pb) {
            onPasteImage?(image)
            return
        }

        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if !hasMarkedText(), isSlashMenuOpenProvider?() == true {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let noModifiers = !flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option)
            if noModifiers {
                switch event.keyCode {
                case 126: // Up arrow
                    onSlashMoveUp?()
                    return
                case 125: // Down arrow
                    onSlashMoveDown?()
                    return
                case 48: // Tab
                    onSlashConfirm?()
                    return
                case 53: // Escape
                    onSlashDismiss?()
                    return
                default:
                    if isReturn && !flags.contains(.shift) {
                        onSlashConfirm?()
                        return
                    }
                }
            }
        }
        if isReturn && !hasMarkedText() {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            if !flags.contains(.command) && !flags.contains(.control) {
                onSubmit?()
                return
            }
        }
        super.keyDown(with: event)
    }
}
