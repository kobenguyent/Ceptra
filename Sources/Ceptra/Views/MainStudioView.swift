import CeptraCore
import SwiftUI

struct MainStudioView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack(alignment: .top) {
            CeptraTheme.canvasBG.ignoresSafeArea()

            VStack(spacing: 0) {
                TopStudioBar()

                Divider().overlay(CeptraTheme.border)

                if appState.workspace == nil {
                    WelcomeView()
                } else {
                    workspaceContent
                }
            }

            if let message = appState.bannerMessage {
                ToastBanner(message: message, isError: appState.bannerIsError)
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: appState.bannerMessage)
        .sheet(isPresented: $appState.showingNewFileSheet) {
            NewFileSheetView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingUpdateSheet) {
            UpdateSheetView()
                .environmentObject(appState)
        }
    }

    private var workspaceContent: some View {
        HSplitView {
            if appState.isSidebarVisible {
                SidebarExplorerView()
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
            }

            VSplitView {
                centerPane
                    .frame(minHeight: 300)

                if appState.isConsoleVisible {
                    ConsoleDrawerView()
                        .frame(minHeight: 150, idealHeight: 220, maxHeight: 420)
                }
            }
        }
    }

    @ViewBuilder
    private var centerPane: some View {
        if appState.workspaceMode == .reports {
            ReportsDashboardView()
        } else {
            VStack(spacing: 0) {
                EditorTabBar()
                Divider().overlay(CeptraTheme.border)

                if let activeTab = appState.activeTab {
                    switch appState.workspaceMode {
                    case .code:
                        editorSurface(for: activeTab)
                    case .visual:
                        FlowVisualizerView(
                            file: appState.activeWorkspaceFile,
                            features: appState.activeFeaturesForCurrentTab
                        )
                    case .split:
                        HSplitView {
                            editorSurface(for: activeTab)
                                .frame(minWidth: 340)
                            FlowVisualizerView(
                                file: appState.activeWorkspaceFile,
                                features: appState.activeFeaturesForCurrentTab
                            )
                            .frame(minWidth: 300, idealWidth: 420)
                        }
                    case .reports:
                        EmptyView()
                    }
                } else {
                    emptyEditorPlaceholder
                }
            }
        }
    }

    private func editorSurface(for tab: OpenDocumentTab) -> some View {
        let boundPath = tab.filePath
        return CodeEditorView(
            documentID: boundPath,
            text: Binding(
                get: { appState.openTabs.first(where: { $0.filePath == boundPath })?.content ?? tab.content },
                set: { appState.updateTabContent(filePath: boundPath, newText: $0) }
            ),
            language: tab.language,
            fontSize: CGFloat(appState.settings.editorFontSize),
            workspace: appState.workspace,
            completionIndex: appState.completionIndex,
            jumpToLine: $appState.pendingJumpToLine,
            goToDefinitionTrigger: appState.goToDefinitionTrigger,
            onNavigate: { target, fromLine in
                appState.navigateToImportTarget(target, fromLine: fromLine)
            }
        )
    }

    private var emptyEditorPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(CeptraTheme.textMuted)
            Text("Select a test suite, feature, or config file")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CeptraTheme.textSecondary)
            Button("New File from Template…") {
                appState.showingNewFileSheet = true
            }
            .buttonStyle(.borderedProminent)
            .tint(CeptraTheme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CeptraTheme.canvasBG)
    }
}

// MARK: - Top Studio Toolbar

private struct TopStudioBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Left traffic-light spacing + Sidebar toggle + Project menu
            Color.clear.frame(width: 66, height: 1)

            if appState.workspace != nil {
                Button {
                    appState.isSidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 13))
                        .foregroundStyle(appState.isSidebarVisible ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Toggle Sidebar (⌘B)")
            }

            Menu {
                Button("Open Workspace Folder…") { appState.openWorkspacePanel() }
                Button("Create Sample CodeceptJS 4.x Workspace…") { appState.createSampleWorkspacePanel() }
                if !appState.settings.recentProjectPaths.isEmpty {
                    Divider()
                    ForEach(appState.settings.recentProjectPaths, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) {
                            appState.openWorkspace(at: URL(fileURLWithPath: path))
                        }
                    }
                }
                if appState.workspace != nil {
                    Divider()
                    Button("Rescan Workspace") { appState.rescanWorkspace() }
                    Button("Reveal in Finder") {
                        if let root = appState.workspace?.rootURL {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(CeptraTheme.accent)
                        .frame(width: 7, height: 7)
                    Text(appState.workspace?.config.projectName ?? "Ceptra")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    if let ver = appState.workspace?.config.packageCodeceptVersion {
                        Text(ver)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(CeptraTheme.border, lineWidth: 0.75))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Active Config File Switcher (supports custom names, nested paths, and external paths)
            if let ws = appState.workspace {
                let activeLabel = ws.config.displayConfigPath(relativeTo: ws.rootURL) ?? "Select Config…"
                Menu {
                    if !ws.discoveredConfigPaths.isEmpty {
                        Section("Detected Configs") {
                            ForEach(ws.discoveredConfigPaths, id: \.self) { path in
                                let isActive = path == ws.config.configFilePath
                                let label = displayPath(path, relativeTo: ws.rootURL)
                                Button {
                                    appState.setCustomConfigFile(path: path)
                                } label: {
                                    if isActive {
                                        Label(label, systemImage: "checkmark")
                                    } else {
                                        Text(label)
                                    }
                                }
                            }
                        }
                        Divider()
                    }

                    Button("Choose Custom Config File…") {
                        appState.selectCustomConfigPanel()
                    }

                    if ws.config.configFilePath != nil {
                        Button("Open Active Config in Editor") {
                            appState.openActiveConfigFile()
                        }
                    }

                    if ws.config.isCustomConfigOverride {
                        Divider()
                        Button("Reset to Auto-Detect") {
                            appState.setCustomConfigFile(path: nil)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: ws.config.configFilePath == nil ? "exclamationmark.triangle" : "gearshape")
                            .font(.system(size: 10))
                            .foregroundStyle(ws.config.configFilePath == nil ? CeptraTheme.warning : (ws.config.isCustomConfigOverride ? CeptraTheme.accentWarm : CeptraTheme.textMuted))
                        Text(activeLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ws.config.configFilePath == nil ? CeptraTheme.warning : CeptraTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 190, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(ws.config.isCustomConfigOverride ? CeptraTheme.accentWarm.opacity(0.45) : CeptraTheme.border, lineWidth: 0.75)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(ws.config.configFilePath ?? "Choose a custom CodeceptJS config file (-c)")
            }

            Spacer()

            // Center Segmented Workspace Switcher
            if appState.workspace != nil {
                HStack(spacing: 2) {
                    ForEach(WorkspaceViewMode.allCases) { mode in
                        Button {
                            appState.workspaceMode = mode
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: mode.symbolName)
                                    .font(.system(size: 11))
                                Text(mode.rawValue)
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundStyle(appState.workspaceMode == mode ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                appState.workspaceMode == mode ? CeptraTheme.elevatedBG : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(CeptraTheme.border, lineWidth: 0.75))
            }

            Spacer()

            // Right Execution & Update Cluster
            if appState.workspace != nil {
                HStack(spacing: 6) {
                    if appState.isRunning {
                        Button {
                            appState.stopActiveRun()
                        } label: {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.mini).scaleEffect(0.75)
                                Text("Stop")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(CeptraTheme.failure, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("Stop Running Tests (⌘.)")
                    } else {
                        Button {
                            appState.run(mode: .runAll)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10))
                                Text("Run All")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(CeptraTheme.success.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("Run All Tests (⌘R)")

                        Menu {
                            if appState.isActiveTabExecutableTestFile {
                                Button("Run Current Test File (⌘⇧R)") { appState.runActiveFile() }
                            }
                            Button("Dry Run (Validate & List)") { appState.run(mode: .dryRun(relativePath: nil)) }
                            Button("Run Parallel Workers (\(appState.runOptions.workerCount)x \(appState.runOptions.workerStrategy.rawValue))") {
                                appState.run(mode: .runWorkers(count: appState.runOptions.workerCount, strategy: appState.runOptions.workerStrategy))
                            }
                            Button("Re-run Last Failed") { appState.run(mode: .runLastFailed) }
                            Divider()
                            Button("Check Environment (check)") { appState.run(mode: .checkEnvironment) }
                            Button("Generate Type Defs (def)") { appState.run(mode: .generateDefinitions) }
                            Button("List I.* Actions (list)") { appState.run(mode: .listActions) }
                            if let pm = appState.workspace?.packageManager {
                                Divider()
                                Button("Install Dependencies (\(pm.rawValue) install)") {
                                    appState.runDependencyAction(.install)
                                }
                                Button("Update Dependencies (\(PackageManagerSupport.commandPreview(for: .update, packageManager: pm)))") {
                                    appState.runDependencyAction(.update)
                                }
                                Button("Update CodeceptJS (@latest)") {
                                    appState.runDependencyAction(.upgradeCodeceptJS)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(CeptraTheme.textSecondary)
                                .frame(width: 24, height: 24)
                                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(CeptraTheme.border, lineWidth: 0.75))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    Button {
                        appState.showingRunOptionsPopover.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 12))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .frame(width: 26, height: 24)
                            .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(CeptraTheme.border, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .help("CodeceptJS Run Options")
                    .popover(isPresented: $appState.showingRunOptionsPopover) {
                        RunOptionsPopover()
                            .environmentObject(appState)
                    }

                    Button {
                        appState.isConsoleVisible.toggle()
                    } label: {
                        Image(systemName: "terminal")
                            .font(.system(size: 12))
                            .foregroundStyle(appState.isConsoleVisible ? CeptraTheme.accent : CeptraTheme.textSecondary)
                            .frame(width: 26, height: 24)
                            .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(CeptraTheme.border, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Console (⌘J)")
                }
            }

            // Update pill button
            Button {
                appState.showingUpdateSheet = true
                if case .idle = appState.updateState {
                    Task { await appState.checkForUpdates(userInitiated: true) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: appState.updateState.hasActionableUpdate ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11.5))
                    if appState.updateState.hasActionableUpdate {
                        Text("Update")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(appState.updateState.hasActionableUpdate ? CeptraTheme.accentWarm : CeptraTheme.textMuted)
                .padding(.horizontal, appState.updateState.hasActionableUpdate ? 8 : 6)
                .padding(.vertical, 4)
                .background(
                    appState.updateState.hasActionableUpdate ? CeptraTheme.accentWarm.opacity(0.14) : Color.clear,
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .help("Check for Updates via GitHub Releases")
        }
        .padding(.trailing, 14)
        .frame(height: 44)
        .background(CeptraTheme.sidebarBG)
    }

    private func displayPath(_ path: String, relativeTo root: URL) -> String {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let stdRoot = root.standardizedFileURL.path
        let prefix = stdRoot.hasSuffix("/") ? stdRoot : stdRoot + "/"
        if stdPath.hasPrefix(prefix) {
            return String(stdPath.dropFirst(prefix.count))
        }
        return stdPath
    }
}

// MARK: - Editor Tab Bar

private struct EditorTabBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Back / Forward import-navigation history buttons
            if appState.canNavigateBack || appState.canNavigateForward {
                HStack(spacing: 2) {
                    Button {
                        appState.navigateBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(appState.canNavigateBack ? CeptraTheme.textSecondary : CeptraTheme.textMuted.opacity(0.4))
                            .frame(width: 22, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(!appState.canNavigateBack)
                    .help("Navigate Back (⌃-)")

                    Button {
                        appState.navigateForward()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(appState.canNavigateForward ? CeptraTheme.textSecondary : CeptraTheme.textMuted.opacity(0.4))
                            .frame(width: 22, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(!appState.canNavigateForward)
                    .help("Navigate Forward (⌃⇧-)")
                }
                .padding(.leading, 6)

                Divider()
                    .frame(height: 16)
                    .overlay(CeptraTheme.border)
                    .padding(.horizontal, 4)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(appState.openTabs) { tab in
                        let isActive = tab.filePath == appState.activeTabPath
                        HStack(spacing: 4) {
                            Button {
                                appState.switchTab(to: tab.filePath)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: tab.category.symbolName)
                                        .font(.system(size: 10))
                                        .foregroundStyle(tab.isExecutableTestFile ? CeptraTheme.accent : CeptraTheme.textMuted)
                                    Text(tab.name)
                                        .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                                        .foregroundStyle(isActive ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                                        .lineLimit(1)
                                    if tab.isDirty {
                                        Circle()
                                            .fill(CeptraTheme.accentWarm)
                                            .frame(width: 6, height: 6)
                                    }
                                }
                                .padding(.leading, 9)
                                .padding(.trailing, 4)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(tab.relativePath)

                            Button {
                                appState.closeTab(filePath: tab.filePath)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(CeptraTheme.textMuted)
                                    .frame(width: 18, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 4)
                        }
                        .background(isActive ? CeptraTheme.canvasBG : Color.clear)
                        .overlay(alignment: .bottom) {
                            if isActive {
                                Rectangle().fill(CeptraTheme.accent).frame(height: 2)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            if let tab = appState.activeTab {
                HStack(spacing: 8) {
                    if tab.isDirty {
                        Button("Save") {
                            appState.saveActiveFile()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    if tab.isExecutableTestFile || tab.language == "javascript" || tab.language == "typescript" {
                        Menu {
                            ForEach(CodeSnippetItem.builtInSnippets) { snippet in
                                Button {
                                    appState.insertSnippet(snippet)
                                } label: {
                                    Text("\(snippet.title) — \(snippet.subtitle)")
                                }
                            }
                        } label: {
                            Label("Snippet", systemImage: "curlybraces.square")
                                .font(.system(size: 11))
                                .foregroundStyle(CeptraTheme.textSecondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    // Show execution button ONLY for CodeceptJS test suites and Gherkin feature files
                    if appState.isActiveTabExecutableTestFile {
                        Button {
                            appState.runActiveFile()
                        } label: {
                            Label("Run Test File", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CeptraTheme.success)
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isRunning)
                        .help("Run \(tab.name) (⌘⇧R)")
                    }
                }
                .padding(.trailing, 10)
            }
        }
        .frame(height: 32)
        .background(CeptraTheme.sidebarBG)
    }
}

// MARK: - Run Options Popover

private struct RunOptionsPopover: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CodeceptJS 4.x Run Options")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CeptraTheme.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show Steps (--steps)", isOn: $appState.runOptions.showSteps)
                Toggle("Debug Output (--debug)", isOn: $appState.runOptions.debug)
                Toggle("Verbose Logging (--verbose)", isOn: $appState.runOptions.verbose)
                Toggle("Enable AI Assistant (--ai)", isOn: $appState.runOptions.aiEnabled)
                Toggle("Bail on First Failure (--bail)", isOn: $appState.runOptions.bailOnFail)
                Toggle("Disable Timeouts (--no-timeouts)", isOn: $appState.runOptions.noTimeouts)
                Toggle("ESM/CJS Named-Export Compat (uuid, etc.)", isOn: $appState.runOptions.esmCjsCompat)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Plugins (-p)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textSecondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(RunOptions.availableQuickPlugins, id: \.self) { plugin in
                        let isEnabled = appState.runOptions.enabledPlugins.contains(plugin)
                        Toggle(plugin, isOn: Binding(
                            get: { isEnabled },
                            set: { checked in
                                if checked {
                                    if !appState.runOptions.enabledPlugins.contains(plugin) {
                                        appState.runOptions.enabledPlugins.append(plugin)
                                    }
                                } else {
                                    appState.runOptions.enabledPlugins.removeAll { $0 == plugin }
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Profile:")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    TextField("e.g. chromium", text: $appState.runOptions.profile)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                }
                GridRow {
                    Text("Grep:")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    TextField("Regex or @tag", text: $appState.runOptions.grepPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                }
                GridRow {
                    Text("Workers:")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    HStack {
                        Stepper("\(appState.runOptions.workerCount)", value: $appState.runOptions.workerCount, in: 1...16)
                            .font(.system(size: 11.5))
                        Picker("", selection: $appState.runOptions.workerStrategy) {
                            ForEach(WorkerStrategy.allCases, id: \.self) { strat in
                                Text(strat.rawValue).tag(strat)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 82)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onDisappear { appState.saveSettings() }
    }
}

private struct ToastBanner: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? CeptraTheme.failure : CeptraTheme.success)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CeptraTheme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(CeptraTheme.elevatedBG, in: Capsule())
        .overlay(Capsule().stroke((isError ? CeptraTheme.failure : CeptraTheme.success).opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}
