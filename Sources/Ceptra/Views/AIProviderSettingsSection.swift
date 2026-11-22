import AppKit
import CeptraCore
import SwiftUI

struct AIProviderSettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedProfileID: UUID? = nil
    @State private var showingAddGallery: Bool = false
    @State private var apiKeyDraft: String = ""
    @State private var customPullModelDraft: String = ""
    @State private var showAdvancedSettings: Bool = false
    @State private var showModelCatalog: Bool = false
    @State private var pendingDeleteOllamaModel: String? = nil

    private var selectedProfileIndex: Int? {
        if let id = selectedProfileID {
            return appState.settings.aiSettings.profiles.firstIndex(where: { $0.id == id })
        }
        if let activeID = appState.settings.aiSettings.activeProfileID {
            return appState.settings.aiSettings.profiles.firstIndex(where: { $0.id == activeID })
        }
        return appState.settings.aiSettings.profiles.isEmpty ? nil : 0
    }

    var body: some View {
        HStack(spacing: 0) {
            profileListSidebar
                .frame(width: 238)
                .background(CeptraTheme.sidebarBG)

            Divider().overlay(CeptraTheme.border)

            if showingAddGallery || appState.aiProfiles.isEmpty {
                addProviderGalleryPane
            } else if let idx = selectedProfileIndex {
                profileDetailPane(index: idx)
            } else {
                addProviderGalleryPane
            }
        }
        .onAppear {
            appState.refreshDetectedAICLIs()
            if appState.aiSettingsStartInAddGallery {
                showingAddGallery = true
                appState.aiSettingsStartInAddGallery = false
            } else if let initialID = appState.aiSettingsInitialProfileID {
                selectedProfileID = initialID
                showingAddGallery = false
                appState.aiSettingsInitialProfileID = nil
            } else if selectedProfileID == nil {
                selectedProfileID = appState.settings.aiSettings.activeProfileID ?? appState.settings.aiSettings.profiles.first?.id
            }
            Task { await appState.refreshOllamaStatus() }
        }
        .onChange(of: selectedProfileID) { _, newID in
            apiKeyDraft = ""
            showAdvancedSettings = false
            if let id = newID,
               let profile = appState.aiProfiles.first(where: { $0.id == id }),
               profile.kind == .ollama {
                Task { await appState.refreshOllamaStatus(for: profile) }
            }
        }
        .alert(
            "Remove Local Ollama Model?",
            isPresented: Binding(
                get: { pendingDeleteOllamaModel != nil },
                set: { if !$0 { pendingDeleteOllamaModel = nil } }
            ),
            presenting: pendingDeleteOllamaModel
        ) { modelName in
            Button("Cancel", role: .cancel) {
                pendingDeleteOllamaModel = nil
            }
            Button("Delete Model", role: .destructive) {
                let name = modelName
                pendingDeleteOllamaModel = nil
                Task { await appState.deleteOllamaModel(name) }
            }
        } message: { modelName in
            Text("This removes \"\(modelName)\" from your local Ollama storage via DELETE /api/delete. You can re-download it anytime.")
        }
    }

    // MARK: - Left Profile Rail & Honest CLI Detection Footer

    private var profileListSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PROVIDERS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(CeptraTheme.textMuted)
                Spacer()
                Button {
                    showingAddGallery = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Add Provider")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(CeptraTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(CeptraTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.96))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(CeptraTheme.border)

            if appState.aiProfiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(CeptraTheme.textMuted)
                    Text("No providers yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Text("Pick any provider from the gallery on the right to get started.")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(appState.aiProfiles) { profile in
                            let isSelected = !showingAddGallery && (selectedProfileID ?? appState.activeAIProfile?.id) == profile.id
                            let isActive = appState.activeAIProfile?.id == profile.id
                            let status = sidebarStatusInfo(for: profile)

                            Button {
                                selectedProfileID = profile.id
                                showingAddGallery = false
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(status.color)
                                        .frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(profile.shortDisplayTitle)
                                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                                .foregroundStyle(CeptraTheme.textPrimary)
                                                .lineLimit(1)
                                            if isActive {
                                                Text("ACTIVE")
                                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                                    .foregroundStyle(CeptraTheme.success)
                                                    .padding(.horizontal, 4.5)
                                                    .padding(.vertical, 1)
                                                    .background(CeptraTheme.success.opacity(0.14), in: Capsule())
                                            }
                                        }
                                        Text(profile.modelID.isEmpty ? status.label : profile.modelID)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(CeptraTheme.textMuted)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 2)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7.5)
                                .background(
                                    isSelected ? CeptraTheme.accent.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(isSelected ? CeptraTheme.accent.opacity(0.32) : Color.clear, lineWidth: 0.75)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }

            Divider().overlay(CeptraTheme.border)

            VStack(alignment: .leading, spacing: 5) {
                Text("LOCAL CLI DETECTION")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(CeptraTheme.textMuted)

                ForEach(appState.detectedAICLIs) { cli in
                    let verifiedProfile = appState.aiProfiles.first(where: {
                        $0.kind == cli.kind && appState.aiConnectionStatusByProfileID[$0.id]?.ok == true
                    })
                    let isVerified = verifiedProfile != nil
                    let badgeText = isVerified ? "Verified" : (cli.isInstalled ? "CLI login" : "Not found")
                    let badgeColor: Color = isVerified
                        ? CeptraTheme.success
                        : (cli.isInstalled ? CeptraTheme.cyan : CeptraTheme.textMuted)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(cli.isInstalled || isVerified ? badgeColor : CeptraTheme.textMuted.opacity(0.35))
                            .frame(width: 6, height: 6)
                        Text(cli.kind.shortName)
                            .font(.system(size: 11))
                            .foregroundStyle(cli.isInstalled ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                        Spacer()
                        Text(badgeText)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(badgeColor)
                    }
                    .help(
                        cli.isInstalled
                            ? "Executable detected at \(cli.executablePath ?? ""). Uses your local terminal login — no API key needed in Ceptra."
                            : "CLI not detected on PATH. Add \(cli.kind.displayName) for install steps."
                    )
                }

                Text("CLI found = binary installed on Mac (uses your terminal login; click Verify to test).")
                    .font(.system(size: 9.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(11)
        }
    }

    // MARK: - Visual Add-Provider Gallery

    private var addProviderGalleryPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add an AI Provider")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        Text("Choose a free private local model, a Keychain-secured cloud API, or a local CLI subscription you already use.")
                            .font(.system(size: 12))
                            .foregroundStyle(CeptraTheme.textSecondary)
                    }
                    Spacer()
                    if !appState.aiProfiles.isEmpty {
                        Button("Back") {
                            showingAddGallery = false
                        }
                        .controlSize(.small)
                    }
                }

                galleryGroup(
                    title: "LOCAL & PRIVATE (NO API KEY)",
                    kinds: [.ollama, .openAICompatible]
                )

                galleryGroup(
                    title: "CLOUD APIS (SECURED IN MACOS KEYCHAIN)",
                    kinds: [.anthropic, .openAI, .gemini, .githubModels]
                )

                galleryGroup(
                    title: "LOCAL CLI SUBSCRIPTIONS (USES YOUR TERMINAL SIGN-IN)",
                    kinds: [.claudeCLI, .copilotCLI, .codexCLI]
                )
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func galleryGroup(title: String, kinds: [AIProviderKind]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.65)
                .foregroundStyle(CeptraTheme.textMuted)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(kinds) { kind in
                    galleryCard(for: kind)
                }
            }
        }
    }

    private func galleryCard(for kind: AIProviderKind) -> some View {
        let alreadyAdded = appState.aiProfiles.contains(where: { $0.kind == kind })
        let badge = galleryBadge(for: kind)

        return Button {
            addAndSelect(kind)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(providerAccent(for: kind))
                        .frame(width: 28, height: 28)
                        .background(providerAccent(for: kind).opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                            .lineLimit(1)
                        if alreadyAdded {
                            Text("Added")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(CeptraTheme.success)
                        }
                    }

                    Spacer(minLength: 4)

                    if let badge {
                        Text(badge.text)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(badge.color)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2)
                            .background(badge.color.opacity(0.12), in: Capsule())
                    }
                }

                Text(kind.helpSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(CeptraTheme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.985))
    }

    private func galleryBadge(for kind: AIProviderKind) -> (text: String, color: Color)? {
        if kind == .ollama {
            switch appState.ollamaStatus {
            case .running(let models):
                return ("\(models.count) ready", CeptraTheme.success)
            case .runningNoModels:
                return ("Pull model", CeptraTheme.accent)
            case .installedNotRunning:
                return ("Stopped", CeptraTheme.warning)
            case .notInstalled, .unknown, .remoteUnreachable:
                return ("Guided setup", CeptraTheme.accent)
            }
        }
        if kind.isCLI {
            let found = appState.detectedAICLIs.first(where: { $0.kind == kind })?.isInstalled ?? false
            return found ? ("CLI found", CeptraTheme.cyan) : ("Install guide", CeptraTheme.textMuted)
        }
        if let badge = kind.setupBadgeText {
            return (badge, CeptraTheme.success)
        }
        return nil
    }

    // MARK: - Tailored Provider Detail Pane

    private func profileDetailPane(index: Int) -> some View {
        let profile = appState.settings.aiSettings.profiles[index]
        let isActive = appState.activeAIProfile?.id == profile.id
        let _ = appState.aiKeychainRevision
        let connResult = appState.aiConnectionStatusByProfileID[profile.id]

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header Row
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: profile.kind.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(providerAccent(for: profile.kind))
                        .frame(width: 32, height: 32)
                        .background(providerAccent(for: profile.kind).opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.shortDisplayTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        Text(profile.kind.helpSubtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(CeptraTheme.textSecondary)
                    }
                    Spacer()

                    if !isActive {
                        Button("Set Active") {
                            appState.selectAIProfile(id: profile.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        CeptraBadge(text: "Active", color: CeptraTheme.success, icon: "checkmark.circle.fill")
                    }

                    Button(role: .destructive) {
                        let deleteID = profile.id
                        appState.deleteAIProfile(id: deleteID)
                        selectedProfileID = appState.activeAIProfile?.id
                        if appState.aiProfiles.isEmpty { showingAddGallery = true }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11.5))
                    }
                    .controlSize(.small)
                    .help("Delete Profile")
                }

                Divider().overlay(CeptraTheme.border)

                // Provider-Tailored Guided Setup Section
                if profile.kind == .ollama {
                    ollamaGuidedSetupSection(index: index, profile: profile)
                } else if profile.kind == .openAICompatible {
                    openAICompatibleGuidedSection(index: index, profile: profile)
                } else if profile.kind.isCLI {
                    cliGuidedSetupSection(index: index, profile: profile)
                } else {
                    cloudAPIGuidedSetupSection(index: index, profile: profile)
                }

                if let connResult, profile.kind != .ollama {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: connResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(connResult.ok ? CeptraTheme.success : CeptraTheme.failure)
                        Text(connResult.summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(connResult.ok ? CeptraTheme.textPrimary : CeptraTheme.failure)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (connResult.ok ? CeptraTheme.success : CeptraTheme.failure).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }

                // Collapsible Advanced Connection & Generation Settings
                advancedSettingsDisclosure(index: index, profile: profile)

                Divider().overlay(CeptraTheme.border)

                // Privacy & CodeceptJS --ai Bridge
                privacyAndBridgeSection(profile: profile)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 1. Local Ollama Guided Setup & Streaming Model Manager

    @ViewBuilder
    private func ollamaGuidedSetupSection(index: Int, profile: AIProviderProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Live Status Banner
            ollamaStatusBanner(for: profile)

            if let pullErr = appState.ollamaPullError, !pullErr.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(CeptraTheme.failure)
                    Text(pullErr)
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.failure)
                    Spacer()
                    Button {
                        appState.ollamaPullError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(CeptraTheme.failure.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Active Download Progress Card
            if let pull = appState.ollamaPullProgress {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Downloading \(pull.modelName)")
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        Spacer()
                        if let bytesText = pull.byteProgressText {
                            Text(bytesText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textSecondary)
                        }
                        if let pctText = pull.percentageText {
                            Text(pctText)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(CeptraTheme.accent)
                        }
                        Button("Cancel") {
                            appState.cancelOllamaModelPull()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CeptraTheme.failure)
                        .buttonStyle(.plain)
                    }

                    if let fraction = pull.fraction {
                        ProgressView(value: fraction)
                            .tint(CeptraTheme.accent)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(CeptraTheme.accent)
                    }

                    Text("POST /api/pull · \(pull.status)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .padding(12)
                .background(CeptraTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(CeptraTheme.accent.opacity(0.32), lineWidth: 1)
                )
            }

            // Installed Local Models + Model Catalog (when Ollama is running)
            if appState.ollamaStatus.isRunning {
                let installed = appState.ollamaStatus.installedModels

                if !installed.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("INSTALLED LOCAL MODELS (\(installed.count))")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.65)
                            .foregroundStyle(CeptraTheme.textMuted)

                        ForEach(installed) { model in
                            let isSelected = profile.modelID == model.name
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(model.name)
                                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(CeptraTheme.textPrimary)
                                        if !model.formattedSize.isEmpty {
                                            Text(model.formattedSize)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(CeptraTheme.textSecondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1.5)
                                                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        }
                                    }
                                    if !model.compactDetails.isEmpty {
                                        Text(model.compactDetails)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(CeptraTheme.textMuted)
                                    }
                                }
                                Spacer()

                                if isSelected {
                                    Text("Active")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(CeptraTheme.accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(CeptraTheme.accent.opacity(0.14), in: Capsule())
                                } else {
                                    Button("Use") {
                                        appState.selectAIModel(model.name, for: profile.id)
                                    }
                                    .controlSize(.small)
                                }

                                Button {
                                    pendingDeleteOllamaModel = model.name
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(CeptraTheme.textMuted)
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .help("Remove \(model.name) from Ollama")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                isSelected ? CeptraTheme.accent.opacity(0.09) : CeptraTheme.canvasBG,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(isSelected ? CeptraTheme.accent.opacity(0.35) : CeptraTheme.border, lineWidth: 1)
                            )
                        }
                    }
                }

                // Recommended Coding Models Catalog + Custom Pull
                let installedSet = Set(installed.map(\.name))
                let unpulledCatalog = OllamaCatalogModel.recommendedCodingModels.filter { !installedSet.contains($0.id) }
                let expanded = installed.isEmpty || showModelCatalog

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        showModelCatalog.toggle()
                    } label: {
                        HStack {
                            Text("Install Recommended Coding Models")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(CeptraTheme.textPrimary)
                            Spacer()
                            Text(expanded ? "Hide" : "Browse & Install")
                                .font(.system(size: 11))
                                .foregroundStyle(CeptraTheme.textMuted)
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(CeptraTheme.panelBG)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(installed.isEmpty)

                    if expanded {
                        Divider().overlay(CeptraTheme.border)
                        VStack(spacing: 8) {
                            ForEach(unpulledCatalog) { item in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.id)
                                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(CeptraTheme.textPrimary)
                                            Text("\(item.approximateSize) · \(item.ramHint)")
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(CeptraTheme.textMuted)
                                            if let badge = item.badge {
                                                Text(badge)
                                                    .font(.system(size: 9.5, weight: .semibold))
                                                    .foregroundStyle(CeptraTheme.success)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1.5)
                                                    .background(CeptraTheme.success.opacity(0.14), in: Capsule())
                                            }
                                        }
                                        Text(item.summary)
                                            .font(.system(size: 11))
                                            .foregroundStyle(CeptraTheme.textSecondary)
                                    }
                                    Spacer()
                                    Button {
                                        appState.pullOllamaModel(item.id, for: profile)
                                    } label: {
                                        Label("Install", systemImage: "arrow.down.circle.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(appState.ollamaPullProgress != nil)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(CeptraTheme.sidebarBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 0.75))
                            }

                            // Custom Model Pull Input
                            HStack(spacing: 8) {
                                TextField("Pull any Ollama model tag (e.g. gemma3:4b, codellama:7b)…", text: $customPullModelDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .onSubmit {
                                        let name = customPullModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !name.isEmpty {
                                            appState.pullOllamaModel(name, for: profile)
                                            customPullModelDraft = ""
                                        }
                                    }
                                Button("Pull Model") {
                                    let name = customPullModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !name.isEmpty {
                                        appState.pullOllamaModel(name, for: profile)
                                        customPullModelDraft = ""
                                    }
                                }
                                .controlSize(.small)
                                .disabled(customPullModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.ollamaPullProgress != nil)
                            }
                            .padding(.top, 2)
                        }
                        .padding(11)
                        .background(CeptraTheme.canvasBG)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
            }
        }
    }

    @ViewBuilder
    private func ollamaStatusBanner(for profile: AIProviderProfile) -> some View {
        switch appState.ollamaStatus {
        case .unknown:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking Local Ollama status…")
                    .font(.system(size: 12))
                    .foregroundStyle(CeptraTheme.textSecondary)
                Spacer()
            }
            .padding(12)
            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))

        case .notInstalled(let brewPath):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(CeptraTheme.warning).frame(width: 8, height: 8)
                    Text("Ollama is not installed on this Mac")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                }
                Text("Install Ollama in one click to run free, 100% private local AI models right inside Ceptra.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CeptraTheme.textSecondary)

                if appState.isInstallingOllamaApp {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(appState.ollamaInstallLogLine.isEmpty ? "Installing Ollama via Homebrew…" : appState.ollamaInstallLogLine)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(CeptraTheme.accent)
                                .lineLimit(2)
                            Spacer()
                            Button("Cancel") {
                                appState.cancelOllamaInstall()
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CeptraTheme.failure)
                            .buttonStyle(.plain)
                        }
                        ProgressView().progressViewStyle(.linear).tint(CeptraTheme.accent)
                    }
                    .padding(10)
                    .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    HStack(spacing: 8) {
                        if brewPath != nil {
                            Button {
                                appState.installOllamaViaHomebrew()
                            } label: {
                                Label("Install via Homebrew", systemImage: "shippingbox.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        Button {
                            appState.openOllamaDownloadPage()
                        } label: {
                            Label("Download Ollama.dmg", systemImage: "arrow.up.right.square")
                        }
                        .controlSize(.small)

                        Button("Re-check") {
                            Task { await appState.refreshOllamaStatus(for: profile, force: true) }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CeptraTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CeptraTheme.warning.opacity(0.32), lineWidth: 1))

        case .installedNotRunning(let appURL, let cliURL):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle().fill(CeptraTheme.warning).frame(width: 8, height: 8)
                        Text("Ollama is installed, but not running")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                    }
                    Text("Found \(appURL?.path ?? cliURL?.path ?? "ollama") · server at \(profile.baseURL) is offline.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                Spacer()
                Button {
                    Task { await appState.startLocalOllama() }
                } label: {
                    HStack(spacing: 5) {
                        if appState.isStartingOllama {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(appState.isStartingOllama ? "Starting…" : "Start Ollama")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(appState.isStartingOllama)
            }
            .padding(13)
            .background(CeptraTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CeptraTheme.warning.opacity(0.32), lineWidth: 1))

        case .runningNoModels:
            HStack(spacing: 10) {
                Circle().fill(CeptraTheme.success).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ollama Running on \(profile.baseURL)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Text("Connected! Install a coding model below to start chatting.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                Spacer()
                Button {
                    Task { await appState.refreshOllamaStatus(for: profile, force: true) }
                } label: {
                    if appState.isCheckingOllama {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
            }
            .padding(13)
            .background(CeptraTheme.success.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CeptraTheme.success.opacity(0.32), lineWidth: 1))

        case .running(let models):
            HStack(spacing: 10) {
                Circle().fill(CeptraTheme.success).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ollama Running on \(profile.baseURL)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Text("\(models.count) local model\(models.count == 1 ? "" : "s") installed and ready offline.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                Spacer()
                Button {
                    Task { await appState.refreshOllamaStatus(for: profile, force: true) }
                } label: {
                    if appState.isCheckingOllama {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
            }
            .padding(13)
            .background(CeptraTheme.success.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CeptraTheme.success.opacity(0.32), lineWidth: 1))

        case .remoteUnreachable(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(CeptraTheme.failure)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remote Ollama Endpoint Unreachable")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.failure)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                Spacer()
                Button("Retry") {
                    Task { await appState.refreshOllamaStatus(for: profile, force: true) }
                }
                .controlSize(.small)
            }
            .padding(13)
            .background(CeptraTheme.failure.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CeptraTheme.failure.opacity(0.32), lineWidth: 1))
        }
    }

    // MARK: - 2. OpenAI-Compatible Guided Setup (1-Click Presets)

    private func openAICompatibleGuidedSection(index: Int, profile: AIProviderProfile) -> some View {
        let activePreset = OpenAICompatiblePreset.matchingPreset(for: profile.baseURL)
        let hasStoredKey = appState.hasAPIKey(for: profile.id)

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("1-CLICK GATEWAY PRESET")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(CeptraTheme.textMuted)

                HStack(spacing: 6) {
                    ForEach(OpenAICompatiblePreset.allPresets) { preset in
                        let isSelected = preset.id == activePreset.id
                        Button {
                            appState.applyOpenAICompatiblePreset(preset, to: profile.id)
                        } label: {
                            Text(preset.name)
                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? CeptraTheme.accent : CeptraTheme.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5.5)
                                .background(
                                    isSelected ? CeptraTheme.accent.opacity(0.14) : CeptraTheme.canvasBG,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(isSelected ? CeptraTheme.accent.opacity(0.45) : CeptraTheme.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.96))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activePreset.hint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(CeptraTheme.textSecondary)
                        Text("Endpoint: \(profile.baseURL)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    Spacer()
                    if let url = activePreset.portalURL, let btnTitle = activePreset.portalButtonTitle {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label(btnTitle, systemImage: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .controlSize(.small)
                    }
                }

                if activePreset.requiresAPIKey || hasStoredKey {
                    keychainSaveAndTestRow(
                        profile: profile,
                        label: "\(activePreset.name) API Key",
                        isRequired: activePreset.requiresAPIKey
                    )
                } else {
                    HStack(spacing: 8) {
                        Button {
                            Task { await appState.testAIProviderConnection(profileID: profile.id) }
                        } label: {
                            HStack(spacing: 5) {
                                if appState.aiTestingProfileID == profile.id {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "bolt.horizontal.circle")
                                }
                                Text("Test Server & Fetch Models")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(appState.aiTestingProfileID == profile.id)
                    }
                }
            }
            .padding(13)
            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))

            modelPickerSection(index: index, profile: profile)
        }
    }

    // MARK: - 3. Cloud API 2-Step Guided Setup (Anthropic, OpenAI, Gemini, GitHub Models)

    private func cloudAPIGuidedSetupSection(index: Int, profile: AIProviderProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Quick 2-Step Setup")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        Text(profile.kind.apiKeySetupHint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(CeptraTheme.textSecondary)
                    }
                    Spacer()
                    if let consoleURL = profile.kind.apiKeyConsoleURL {
                        Button {
                            NSWorkspace.shared.open(consoleURL)
                        } label: {
                            Label("1. Get API Key", systemImage: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .controlSize(.small)
                    }
                }

                keychainSaveAndTestRow(
                    profile: profile,
                    label: "2. \(profile.kind.apiKeyLabel)",
                    isRequired: true
                )
            }
            .padding(13)
            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))

            modelPickerSection(index: index, profile: profile)
        }
    }

    private func keychainSaveAndTestRow(profile: AIProviderProfile, label: String, isRequired: Bool) -> some View {
        let hasStoredKey = appState.hasAPIKey(for: profile.id)
        let isTesting = appState.aiTestingProfileID == profile.id
        let conn = appState.aiConnectionStatusByProfileID[profile.id]
        let hasDraft = !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(CeptraTheme.textPrimary)
                Spacer()
                if hasStoredKey {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9.5))
                        Text(conn?.ok == true ? "Saved in Keychain · Verified (\(conn?.latencyMs ?? 0)ms)" : "Stored in macOS Keychain")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(CeptraTheme.success)
                } else if isRequired {
                    Text("API key required before chatting")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.warning)
                }
            }

            HStack(spacing: 7) {
                SecureField(
                    hasStoredKey ? "•••••••••••• (saved in Keychain — paste to replace)" : "Paste API key here…",
                    text: $apiKeyDraft
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if hasDraft || hasStoredKey {
                        let draft = apiKeyDraft
                        apiKeyDraft = ""
                        Task { await appState.saveAPIKeyAndTest(draft, for: profile.id) }
                    }
                }

                Button {
                    let draft = apiKeyDraft
                    apiKeyDraft = ""
                    Task { await appState.saveAPIKeyAndTest(draft, for: profile.id) }
                } label: {
                    HStack(spacing: 5) {
                        if isTesting {
                            ProgressView().controlSize(.mini)
                        }
                        Text(hasDraft ? "Save & Test" : "Test Connection")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isTesting || (!hasDraft && !hasStoredKey))

                if hasStoredKey {
                    Button("Clear") {
                        appState.deleteAPIKey(for: profile.id)
                        apiKeyDraft = ""
                    }
                    .controlSize(.small)
                    .foregroundStyle(CeptraTheme.failure)
                }
            }
        }
    }

    // MARK: - 4. Local CLI Guided Setup (Claude, Copilot, Codex)

    private func cliGuidedSetupSection(index: Int, profile: AIProviderProfile) -> some View {
        let detected = appState.detectedAICLIs.first(where: { $0.kind == profile.kind })
        let customPath = profile.customCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePath = customPath.isEmpty ? detected?.executablePath : customPath
        let isFound = effectivePath != nil
        let isVerified = appState.aiConnectionStatusByProfileID[profile.id]?.ok == true
        let isTesting = appState.aiTestingProfileID == profile.id

        return VStack(alignment: .leading, spacing: 14) {
            if isFound {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isVerified ? CeptraTheme.success : CeptraTheme.cyan)
                            .frame(width: 8, height: 8)
                        Text(isVerified ? "\(profile.kind.displayName) Verified & Ready" : "\(profile.kind.displayName) Detected (CLI found)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                    }

                    if let effectivePath {
                        Text("Binary: \(effectivePath)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textSecondary)
                    }

                    Text("Reuses your existing local terminal sign-in — no API key needed in Ceptra.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textSecondary)

                    HStack(spacing: 8) {
                        Button {
                            Task { await appState.testAIProviderConnection(profileID: profile.id) }
                        } label: {
                            HStack(spacing: 5) {
                                if isTesting {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "checkmark.shield")
                                }
                                Text(isTesting ? "Verifying…" : "Verify Sign-In & Test")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isTesting)

                        if let loginCmd = profile.kind.cliLoginCommand {
                            Button {
                                appState.openTerminalForCLISetup(
                                    command: loginCmd,
                                    title: "Sign In — \(profile.kind.displayName)"
                                )
                            } label: {
                                Label("Open Login in Terminal (\(loginCmd))", systemImage: "terminal")
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (isVerified ? CeptraTheme.success : CeptraTheme.cyan).opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder((isVerified ? CeptraTheme.success : CeptraTheme.cyan).opacity(0.30), lineWidth: 1)
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(CeptraTheme.warning).frame(width: 8, height: 8)
                        Text("\(profile.kind.displayName) is not installed yet")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                    }
                    Text("Install the CLI and sign in once in Terminal — Ceptra will automatically detect it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textSecondary)

                    if let installCmd = profile.kind.cliInstallCommand {
                        HStack(spacing: 8) {
                            Text(installCmd)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textPrimary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(installCmd, forType: .string)
                                appState.showBanner("Copied install command to clipboard")
                            }
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))

                        HStack(spacing: 8) {
                            Button {
                                appState.openTerminalForCLISetup(
                                    command: installCmd,
                                    title: "Install \(profile.kind.displayName)"
                                )
                            } label: {
                                Label("Open Install in Terminal", systemImage: "terminal")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            if let docsURL = profile.kind.cliDocsURL {
                                Button("Docs ↗") {
                                    NSWorkspace.shared.open(docsURL)
                                }
                                .controlSize(.small)
                            }

                            Button("Re-check") {
                                appState.refreshDetectedAICLIs()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CeptraTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CeptraTheme.warning.opacity(0.32), lineWidth: 1))
            }

            modelPickerSection(index: index, profile: profile)
        }
    }

    // MARK: - Shared Interactive Model Picker (Cloud / Compat / CLI)

    private func modelPickerSection(index: Int, profile: AIProviderProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MODEL")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(CeptraTheme.textMuted)
                Spacer()
                if !profile.kind.isCLI {
                    Button {
                        Task { await appState.fetchModelsForAIProfile(profileID: profile.id) }
                    } label: {
                        if appState.aiFetchingModelsProfileID == profile.id {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("Fetch Live Models", systemImage: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CeptraTheme.accent)
                    .disabled(appState.aiFetchingModelsProfileID == profile.id)
                }
            }

            if !profile.availableModels.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(profile.availableModels.prefix(12), id: \.self) { model in
                        let isSelected = profile.modelID == model
                        Button {
                            appState.selectAIModel(model, for: profile.id)
                        } label: {
                            HStack(spacing: 6) {
                                Text(model)
                                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(CeptraTheme.accent)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7.5)
                            .background(
                                isSelected ? CeptraTheme.accent.opacity(0.12) : CeptraTheme.canvasBG,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isSelected ? CeptraTheme.accent.opacity(0.42) : CeptraTheme.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.985))
                    }
                }
            }

            HStack(spacing: 8) {
                Text("Custom Model ID")
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textMuted)
                TextField(profile.kind.defaultModelID, text: profileBinding(index, keyPath: \.modelID))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
            }
        }
    }

    // MARK: - Collapsible Advanced Connection & Generation Settings

    private func advancedSettingsDisclosure(index: Int, profile: AIProviderProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showAdvancedSettings.toggle()
            } label: {
                HStack {
                    Text("Advanced Connection & Generation Settings")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Spacer()
                    Image(systemName: showAdvancedSettings ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8.5)
                .background(CeptraTheme.panelBG)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvancedSettings {
                Divider().overlay(CeptraTheme.border)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        fieldLabel("Profile Name")
                        TextField("Profile name", text: profileBinding(index, keyPath: \.name))
                            .textFieldStyle(.roundedBorder)
                    }

                    if !profile.kind.isCLI {
                        GridRow {
                            fieldLabel("Base URL")
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(profile.kind.defaultBaseURL, text: profileBinding(index, keyPath: \.baseURL))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                if let validationErr = validateURLMessage(for: profile) {
                                    Text(validationErr)
                                        .font(.system(size: 10))
                                        .foregroundStyle(CeptraTheme.failure)
                                }
                            }
                        }

                        if profile.kind == .ollama || profile.kind == .openAICompatible {
                            GridRow {
                                Color.clear.frame(width: 1, height: 1)
                                Toggle(
                                    "Allow plaintext HTTP on private LAN hosts (192.168.x.x / 10.x.x.x / .local)",
                                    isOn: profileBinding(index, keyPath: \.allowInsecureLocalHTTP)
                                )
                                .font(.system(size: 11))
                            }
                        }

                        if profile.kind == .ollama {
                            GridRow {
                                fieldLabel("Optional Token")
                                keychainSaveAndTestRow(
                                    profile: profile,
                                    label: "Optional Bearer Token (only for proxied remote Ollama)",
                                    isRequired: false
                                )
                            }
                        }
                    } else {
                        GridRow {
                            fieldLabel("CLI Binary")
                            TextField("Auto-detect on PATH (optional custom path)", text: profileBinding(index, keyPath: \.customCLIPath))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                        }
                    }

                    GridRow {
                        fieldLabel("Temperature")
                        HStack(spacing: 8) {
                            Slider(value: profileBinding(index, keyPath: \.temperature), in: 0.0...1.0, step: 0.05)
                            Text(String(format: "%.2f", profile.temperature))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 36, alignment: .trailing)
                        }
                    }

                    GridRow {
                        fieldLabel("Max Tokens")
                        Picker("", selection: profileBinding(index, keyPath: \.maxTokens)) {
                            Text("2,048").tag(2048)
                            Text("4,096").tag(4096)
                            Text("8,192").tag(8192)
                            Text("16,384").tag(16384)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
                .padding(12)
                .background(CeptraTheme.canvasBG)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
    }

    // MARK: - Permissions, Privacy & CodeceptJS --ai Bridge

    private func privacyAndBridgeSection(profile: AIProviderProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions, Privacy & CodeceptJS `--ai` Bridge")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(CeptraTheme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("AI Permission Mode")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Spacer()
                    Picker(
                        "",
                        selection: Binding(
                            get: { appState.settings.aiSettings.permissionMode },
                            set: { appState.setAIPermissionMode($0) }
                        )
                    ) {
                        ForEach(AIPermissionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)
                }

                Text(appState.settings.aiSettings.permissionMode.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textSecondary)

                HStack(spacing: 5) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(CeptraTheme.success)
                    Text("Hard guardrails stay enforced in all modes: ~/.ssh, ~/.aws, Keychain, .env secrets, and files outside your active workspace are always blocked.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
            }
            .padding(10)
            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))

            // Universal Slash Commands & Agent Skills (SKILL.md)
            let builtInCount = appState.aiAvailableSkills.filter { $0.source == .builtIn && !$0.isMetaBrowseCommand }.count
            let projectCount = appState.aiAvailableSkills.filter { $0.source == .workspace }.count
            let globalCount = appState.aiAvailableSkills.filter { $0.source == .userGlobal }.count

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "slash.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CeptraTheme.violet)
                    Text("Slash Commands & Agent Skills (`SKILL.md`)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Spacer()
                    Text("\(builtInCount) built-in · \(projectCount) project · \(globalCount) global")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                }

                Toggle(
                    "Discover personal global skills (~/.ceptra, ~/.agents, ~/.claude, ~/.codex · read-only Markdown)",
                    isOn: Binding(
                        get: { appState.settings.aiSettings.enableGlobalAgentSkills },
                        set: { appState.setEnableGlobalAgentSkills($0) }
                    )
                )
                .font(.system(size: 11))

                HStack(spacing: 8) {
                    Text("Works identically across Local Ollama, Cloud APIs, and CLI agents. Type `/` in the chat box to invoke.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CeptraTheme.textMuted)
                    Spacer()
                    Button("Refresh") {
                        appState.refreshAISkills()
                    }
                    .controlSize(.small)

                    Button("Browse / New Skill…") {
                        appState.showingAIProviderSettingsSheet = false
                        DispatchQueue.main.async {
                            appState.showingAISkillsSheet = true
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))

            Toggle(
                "Automatically redact API keys, Bearer/Cookie headers, and .env secrets before sending context to cloud models",
                isOn: Binding(
                    get: { appState.settings.aiSettings.redactSecretsInCloudContext },
                    set: {
                        appState.settings.aiSettings.redactSecretsInCloudContext = $0
                        appState.saveSettings()
                    }
                )
            )
            .font(.system(size: 11.5))

            Toggle(
                "Bridge active AI provider into CodeceptJS `--ai` & `heal` test runs (Built-in Console only)",
                isOn: Binding(
                    get: { appState.settings.aiSettings.bridgeToCodeceptAI },
                    set: {
                        appState.settings.aiSettings.bridgeToCodeceptAI = $0
                        appState.saveSettings()
                    }
                )
            )
            .font(.system(size: 11.5))

            HStack(spacing: 8) {
                Text("Passes standard env vars (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OLLAMA_HOST`, `CEPTRA_AI_MODEL`) directly to Built-in Console child processes without logging secrets.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                Spacer()
                Button("Copy `codecept.conf` Snippet") {
                    appState.copyCodeceptAIConfigSnippet(for: profile)
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func addAndSelect(_ kind: AIProviderKind) {
        let created = appState.addAIProfile(kind: kind)
        selectedProfileID = created.id
        showingAddGallery = false
        apiKeyDraft = ""
        if kind == .ollama {
            Task { await appState.refreshOllamaStatus(for: created) }
        }
    }

    private func providerAccent(for kind: AIProviderKind) -> Color {
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

    private func sidebarStatusInfo(for profile: AIProviderProfile) -> (color: Color, label: String) {
        if profile.kind == .ollama {
            switch appState.ollamaStatus {
            case .running(let models) where !models.isEmpty:
                return (CeptraTheme.success, "Ready")
            case .runningNoModels, .running:
                return (CeptraTheme.warning, "Install model")
            case .installedNotRunning:
                return (CeptraTheme.warning, "Stopped")
            case .notInstalled:
                return (CeptraTheme.warning, "Setup needed")
            case .remoteUnreachable:
                return (CeptraTheme.failure, "Unreachable")
            case .unknown:
                return (CeptraTheme.textMuted, "Checking…")
            }
        }
        if let conn = appState.aiConnectionStatusByProfileID[profile.id] {
            return conn.ok ? (CeptraTheme.success, "Verified") : (CeptraTheme.failure, "Error")
        }
        if profile.kind.requiresAPIKey && !appState.hasAPIKey(for: profile.id) {
            return (CeptraTheme.warning, "Key needed")
        }
        if profile.kind.isCLI {
            let found = appState.detectedAICLIs.first(where: { $0.kind == profile.kind })?.isInstalled ?? false
            return found ? (CeptraTheme.cyan, "CLI found") : (CeptraTheme.warning, "Not installed")
        }
        return (CeptraTheme.textMuted, "Untested")
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(CeptraTheme.textSecondary)
            .frame(width: 112, alignment: .trailing)
    }

    private func profileBinding<T>(_ index: Int, keyPath: WritableKeyPath<AIProviderProfile, T>) -> Binding<T> {
        Binding(
            get: { appState.settings.aiSettings.profiles[index][keyPath: keyPath] },
            set: { newValue in
                appState.settings.aiSettings.profiles[index][keyPath: keyPath] = newValue
                appState.saveSettings()
            }
        )
    }

    private func validateURLMessage(for profile: AIProviderProfile) -> String? {
        do {
            _ = try AIURLValidator.validateBaseURL(
                profile.baseURL,
                allowInsecureLocalHTTP: profile.allowInsecureLocalHTTP
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct AIProviderSettingsSheetView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("AI Providers & CodeceptJS `--ai` Bridge", systemImage: "sparkles")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                Spacer()
                Button("Done") {
                    appState.showingAIProviderSettingsSheet = false
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(CeptraTheme.panelBG)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }

            AIProviderSettingsView()
                .environmentObject(appState)
        }
        .frame(minWidth: 800, minHeight: 580)
    }
}
