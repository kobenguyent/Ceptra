import CeptraCore
import SwiftUI

struct MainStudioView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            CeptraTheme.canvasBG.ignoresSafeArea()

            VStack(spacing: 0) {
                TopStudioBar()

                if appState.workspace == nil {
                    WelcomeView()
                        .transition(.opacity)
                } else {
                    workspaceContent
                        .transition(.opacity)
                }
            }
            .animation(CeptraMotion.resolve(CeptraMotion.smooth, reduceMotion: reduceMotion), value: appState.workspace == nil)

            if let message = appState.bannerMessage {
                ToastBanner(message: message, isError: appState.bannerIsError)
                    .padding(.top, 54)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top))
                    )
            }
        }
        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: appState.bannerMessage)
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
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }

            VStack(spacing: 0) {
                VSplitView {
                    centerPane
                        .frame(minHeight: 300)

                    if appState.isConsoleVisible {
                        ConsoleDrawerView()
                            .frame(minHeight: 150, idealHeight: 220, maxHeight: 420)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }

                if !appState.isConsoleVisible {
                    ConsoleDrawerView()
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: appState.isConsoleVisible)
        }
        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: appState.isSidebarVisible)
    }

    @ViewBuilder
    private var centerPane: some View {
        Group {
            if appState.workspaceMode == .reports {
                ReportsDashboardView()
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    EditorTabBar()

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
                .transition(.opacity)
            }
        }
        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: appState.workspaceMode)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isRunMenuHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Left traffic-light spacing + Sidebar toggle + Project menu
            Color.clear.frame(width: 66, height: 1)

            if appState.workspace != nil {
                Button {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                        appState.isSidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(appState.isSidebarVisible ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                        .frame(width: 28, height: 26)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(
                    CeptraGlassButtonStyle(
                        cornerRadius: 7,
                        tint: CeptraTheme.panelBG,
                        tintOpacity: 0.50,
                        isActive: appState.isSidebarVisible
                    )
                )
                .help("Toggle Sidebar (⌘B)")
            }

            CeptraGlassDropdown(minWidth: 260, maxWidth: 320) { isOpen in
                CeptraMenuPillLabel(
                    title: appState.workspace?.config.projectName ?? "Ceptra",
                    subtitle: appState.workspace?.config.packageCodeceptVersion,
                    isOpen: isOpen
                ) {
                    Circle()
                        .fill(CeptraTheme.accent)
                        .frame(width: 7, height: 7)
                        .shadow(color: CeptraTheme.accent.opacity(0.75), radius: 3.5)
                }
            } content: {
                CeptraDropdownItem(
                    title: "Open Workspace Folder…",
                    systemImage: "folder.badge.plus",
                    shortcut: "⌘O"
                ) {
                    appState.openWorkspacePanel()
                }
                CeptraDropdownItem(
                    title: "Create Sample CodeceptJS 4.x Workspace…",
                    systemImage: "sparkles",
                    iconColor: CeptraTheme.accent
                ) {
                    appState.createSampleWorkspacePanel()
                }

                if !appState.settings.recentProjectPaths.isEmpty {
                    CeptraDropdownDivider()
                    CeptraDropdownSectionHeader(title: "Recent Workspaces")
                    ForEach(appState.settings.recentProjectPaths, id: \.self) { path in
                        let url = URL(fileURLWithPath: path)
                        let isCurrent = appState.workspace?.rootURL.path == path
                        CeptraDropdownItem(
                            title: url.lastPathComponent,
                            subtitle: url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                            systemImage: "folder",
                            isSelected: isCurrent
                        ) {
                            appState.openWorkspace(at: url)
                        }
                    }
                }

                if appState.workspace != nil {
                    CeptraDropdownDivider()
                    CeptraDropdownItem(
                        title: "Rescan Workspace",
                        systemImage: "arrow.clockwise"
                    ) {
                        appState.rescanWorkspace()
                    }
                    CeptraDropdownItem(
                        title: "Reveal in Finder",
                        systemImage: "macwindow"
                    ) {
                        if let root = appState.workspace?.rootURL {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                    }
                }
            }
            .fixedSize()
            .help("Switch or Manage Workspace")
            .accessibilityLabel("Workspace Menu")

            // Active Config File Switcher (supports custom names, nested paths, and external paths)
            if let ws = appState.workspace {
                let activeLabel = ws.config.displayConfigPath(relativeTo: ws.rootURL) ?? "Select Config…"
                CeptraGlassDropdown(minWidth: 250, maxWidth: 340) { isOpen in
                    CeptraMenuPillLabel(
                        title: activeLabel,
                        titleFont: .system(size: 11, design: .monospaced),
                        titleColor: ws.config.configFilePath == nil ? CeptraTheme.warning : CeptraTheme.textSecondary,
                        maxTitleWidth: 190,
                        accentBorder: ws.config.isCustomConfigOverride ? CeptraTheme.accentWarm : nil,
                        horizontalPadding: 9,
                        verticalPadding: 5,
                        cornerRadius: 8,
                        isOpen: isOpen
                    ) {
                        Image(systemName: ws.config.configFilePath == nil ? "exclamationmark.triangle" : "gearshape")
                            .font(.system(size: 10))
                            .foregroundStyle(
                                ws.config.configFilePath == nil
                                    ? CeptraTheme.warning
                                    : (ws.config.isCustomConfigOverride ? CeptraTheme.accentWarm : CeptraTheme.textMuted)
                            )
                    }
                } content: {
                    if !ws.discoveredConfigPaths.isEmpty {
                        CeptraDropdownSectionHeader(title: "Detected Configs")
                        ForEach(ws.discoveredConfigPaths, id: \.self) { path in
                            let isActive = path == ws.config.configFilePath
                            let label = displayPath(path, relativeTo: ws.rootURL)
                            CeptraDropdownItem(
                                title: label,
                                systemImage: "doc.text",
                                isSelected: isActive,
                                isMonospaced: true
                            ) {
                                appState.setCustomConfigFile(path: path)
                            }
                        }
                        CeptraDropdownDivider()
                    }

                    CeptraDropdownItem(
                        title: "Choose Custom Config File…",
                        systemImage: "folder"
                    ) {
                        appState.selectCustomConfigPanel()
                    }

                    if ws.config.configFilePath != nil {
                        CeptraDropdownItem(
                            title: "Open Active Config in Editor",
                            systemImage: "square.and.pencil"
                        ) {
                            appState.openActiveConfigFile()
                        }
                    }

                    if ws.config.isCustomConfigOverride {
                        CeptraDropdownDivider()
                        CeptraDropdownItem(
                            title: "Reset to Auto-Detect",
                            systemImage: "arrow.counterclockwise",
                            iconColor: CeptraTheme.accentWarm
                        ) {
                            appState.setCustomConfigFile(path: nil)
                        }
                    }
                }
                .fixedSize()
                .help(ws.config.configFilePath ?? "Choose a custom CodeceptJS config file (-c)")
                .accessibilityLabel("Active Config File Switcher")
            }

            Spacer()

            // Center Segmented Workspace Switcher
            if appState.workspace != nil {
                CeptraGlassSegmentedControl(
                    options: WorkspaceViewMode.allCases,
                    selection: $appState.workspaceMode,
                    label: { $0.rawValue },
                    symbol: { $0.symbolName }
                )
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
                            .background(CeptraTheme.failure.opacity(0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(CeptraTheme.specularRimGradient, lineWidth: 0.75)
                            )
                            .shadow(color: CeptraTheme.failure.opacity(0.28), radius: 6, y: 2)
                        }
                        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.96))
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
                            .background(CeptraTheme.success.opacity(0.88), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(CeptraTheme.specularRimGradient, lineWidth: 0.75)
                            )
                            .shadow(color: CeptraTheme.success.opacity(0.24), radius: 6, y: 2)
                        }
                        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.96))
                        .help("Run All Tests (⌘R)")

                        CeptraGlassDropdown(minWidth: 265, maxWidth: 340) { isOpen in
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isOpen || isRunMenuHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                                .rotationEffect(.degrees(isOpen ? 180 : 0))
                                .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: isOpen)
                                .frame(width: 26, height: 26)
                                .ceptraGlassSurface(
                                    cornerRadius: 7,
                                    tint: CeptraTheme.panelBG,
                                    tintOpacity: 0.56,
                                    isHovered: isRunMenuHovered,
                                    isActive: isOpen
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isRunMenuHovered)
                                .onHover { hovering in
                                    isRunMenuHovered = hovering
                                }
                                .onDisappear {
                                    isRunMenuHovered = false
                                }
                        } content: {
                            CeptraDropdownSectionHeader(title: "Run Modes")
                            if appState.isActiveTabExecutableTestFile {
                                CeptraDropdownItem(
                                    title: "Run Current Test File",
                                    systemImage: "play.circle",
                                    iconColor: CeptraTheme.success,
                                    shortcut: "⌘⇧R"
                                ) {
                                    appState.runActiveFile()
                                }
                            }
                            CeptraDropdownItem(
                                title: "Dry Run (Validate & List)",
                                systemImage: "checklist"
                            ) {
                                appState.run(mode: .dryRun(relativePath: nil))
                            }
                            CeptraDropdownItem(
                                title: "Run Parallel Workers",
                                subtitle: "\(appState.runOptions.workerCount)x \(appState.runOptions.workerStrategy.rawValue)",
                                systemImage: "cpu"
                            ) {
                                appState.run(mode: .runWorkers(count: appState.runOptions.workerCount, strategy: appState.runOptions.workerStrategy))
                            }
                            CeptraDropdownItem(
                                title: "Re-run Last Failed",
                                systemImage: "arrow.counterclockwise.circle",
                                iconColor: CeptraTheme.warning
                            ) {
                                appState.run(mode: .runLastFailed)
                            }

                            CeptraDropdownDivider()
                            CeptraDropdownSectionHeader(title: "CodeceptJS Tools")
                            CeptraDropdownItem(
                                title: "Check Environment",
                                subtitle: "codeceptjs check",
                                systemImage: "stethoscope"
                            ) {
                                appState.run(mode: .checkEnvironment)
                            }
                            CeptraDropdownItem(
                                title: "Generate Type Defs",
                                subtitle: "codeceptjs def",
                                systemImage: "curlybraces"
                            ) {
                                appState.run(mode: .generateDefinitions)
                            }
                            CeptraDropdownItem(
                                title: "List I.* Actions",
                                subtitle: "codeceptjs list",
                                systemImage: "list.bullet.rectangle"
                            ) {
                                appState.run(mode: .listActions)
                            }

                            if let pm = appState.workspace?.packageManager {
                                CeptraDropdownDivider()
                                CeptraDropdownSectionHeader(title: "Dependencies (\(pm.rawValue))")
                                CeptraDropdownItem(
                                    title: "Install Dependencies",
                                    subtitle: "\(pm.rawValue) install",
                                    systemImage: "arrow.down.circle"
                                ) {
                                    appState.runDependencyAction(.install)
                                }
                                CeptraDropdownItem(
                                    title: "Update Dependencies",
                                    subtitle: PackageManagerSupport.commandPreview(for: .update, packageManager: pm),
                                    systemImage: "arrow.triangle.2.circlepath"
                                ) {
                                    appState.runDependencyAction(.update)
                                }
                                CeptraDropdownItem(
                                    title: "Update CodeceptJS (@latest)",
                                    systemImage: "arrow.up.circle",
                                    iconColor: CeptraTheme.accent
                                ) {
                                    appState.runDependencyAction(.upgradeCodeceptJS)
                                }
                            }
                        }
                        .fixedSize()
                        .help("More Run & Dependency Actions")
                        .accessibilityLabel("More Run Actions")
                    }

                    Button {
                        appState.showingRunOptionsPopover.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 12))
                            .foregroundStyle(appState.showingRunOptionsPopover ? CeptraTheme.accent : CeptraTheme.textSecondary)
                            .frame(width: 28, height: 26)
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(
                        CeptraGlassButtonStyle(
                            cornerRadius: 7,
                            tint: CeptraTheme.panelBG,
                            tintOpacity: 0.56,
                            accentBorder: appState.showingRunOptionsPopover ? CeptraTheme.accent : nil,
                            isActive: appState.showingRunOptionsPopover
                        )
                    )
                    .help("CodeceptJS Run Options")
                    .popover(isPresented: $appState.showingRunOptionsPopover) {
                        RunOptionsPopover()
                            .environmentObject(appState)
                    }

                    Button {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                            appState.isConsoleVisible.toggle()
                        }
                    } label: {
                        Image(systemName: "terminal")
                            .font(.system(size: 12))
                            .foregroundStyle(appState.isConsoleVisible ? CeptraTheme.accent : CeptraTheme.textSecondary)
                            .frame(width: 28, height: 26)
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(
                        CeptraGlassButtonStyle(
                            cornerRadius: 7,
                            tint: CeptraTheme.panelBG,
                            tintOpacity: 0.56,
                            accentBorder: appState.isConsoleVisible ? CeptraTheme.accent : nil,
                            isActive: appState.isConsoleVisible
                        )
                    )
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
                .padding(.horizontal, appState.updateState.hasActionableUpdate ? 9 : 7)
                .padding(.vertical, 5)
            }
            .buttonStyle(
                CeptraGlassButtonStyle(
                    cornerRadius: 999,
                    tint: appState.updateState.hasActionableUpdate ? CeptraTheme.accentWarm : CeptraTheme.panelBG,
                    tintOpacity: appState.updateState.hasActionableUpdate ? 0.16 : 0.42,
                    accentBorder: appState.updateState.hasActionableUpdate ? CeptraTheme.accentWarm : nil
                )
            )
            .help("Check for Updates via GitHub Releases")
        }
        .padding(.trailing, 14)
        .frame(height: 44)
        .background(CeptraWindowTitlebarDragArea())
        .ceptraGlassBar(tint: CeptraTheme.sidebarBG, tintOpacity: 0.72, bottomHairline: true)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var activeTabNamespace
    @State private var hoveredTabPath: String?
    @State private var hoveredClosePath: String?

    private var hasNavigationHistory: Bool {
        appState.canNavigateBack || appState.canNavigateForward
    }

    var body: some View {
        HStack(spacing: 0) {
            // Back / Forward import-navigation history buttons
            if hasNavigationHistory {
                HStack(spacing: 2) {
                    Button {
                        appState.navigateBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(appState.canNavigateBack ? CeptraTheme.textSecondary : CeptraTheme.textMuted.opacity(0.4))
                            .frame(width: 22, height: 24)
                            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.92))
                    .disabled(!appState.canNavigateBack)
                    .help("Navigate Back (⌃-)")

                    Button {
                        appState.navigateForward()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(appState.canNavigateForward ? CeptraTheme.textSecondary : CeptraTheme.textMuted.opacity(0.4))
                            .frame(width: 22, height: 24)
                            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.92))
                    .disabled(!appState.canNavigateForward)
                    .help("Navigate Forward (⌃⇧-)")
                }
                .padding(.leading, 6)
                .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))

                Divider()
                    .frame(height: 16)
                    .overlay(CeptraTheme.border)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(appState.openTabs) { tab in
                        let isActive = tab.filePath == appState.activeTabPath
                        let isHovered = hoveredTabPath == tab.filePath
                        let isCloseHovered = hoveredClosePath == tab.filePath

                        HStack(spacing: 4) {
                            Button {
                                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                                    appState.switchTab(to: tab.filePath)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: tab.category.symbolName)
                                        .font(.system(size: 10))
                                        .foregroundStyle(tab.isExecutableTestFile ? CeptraTheme.accent : CeptraTheme.textMuted)
                                    Text(tab.name)
                                        .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                                        .foregroundStyle(isActive ? CeptraTheme.textPrimary : (isHovered ? CeptraTheme.textPrimary.opacity(0.88) : CeptraTheme.textSecondary))
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
                                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                                    appState.closeTab(filePath: tab.filePath)
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(isCloseHovered ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                                    .frame(width: 18, height: 18)
                                    .background(
                                        isCloseHovered ? Color.white.opacity(0.10) : Color.clear,
                                        in: Circle()
                                    )
                                    .contentShape(Circle())
                            }
                            .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.90))
                            .padding(.trailing, 5)
                            .help("Close Tab (⌘W)")
                            .accessibilityLabel("Close \(tab.name)")
                            .onHover { hovering in
                                withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                                    hoveredClosePath = hovering ? tab.filePath : (hoveredClosePath == tab.filePath ? nil : hoveredClosePath)
                                }
                            }
                        }
                        .background {
                            if isActive {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(CeptraTheme.canvasBG.opacity(0.92))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(CeptraTheme.specularRimGradient, lineWidth: 0.7)
                                    )
                                    .matchedGeometryEffect(id: "active-editor-tab-bg", in: activeTabNamespace)
                            } else if isHovered {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(CeptraTheme.glassHoverOverlay)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if isActive {
                                Capsule()
                                    .fill(CeptraTheme.accent)
                                    .frame(height: 2)
                                    .padding(.horizontal, 8)
                                    .shadow(color: CeptraTheme.accent.opacity(0.65), radius: 4, y: 0)
                                    .matchedGeometryEffect(id: "active-editor-tab-indicator", in: activeTabNamespace)
                            }
                        }
                        .padding(.vertical, 2)
                        .onHover { hovering in
                            withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                                hoveredTabPath = hovering ? tab.filePath : (hoveredTabPath == tab.filePath ? nil : hoveredTabPath)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer(minLength: 8)

            if let tab = appState.activeTab {
                HStack(spacing: 8) {
                    if tab.isDirty {
                        Button {
                            appState.saveActiveFile()
                        } label: {
                            Text("Save")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(CeptraTheme.accentWarm)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(
                            CeptraGlassButtonStyle(
                                cornerRadius: 6,
                                tint: CeptraTheme.accentWarm,
                                tintOpacity: 0.14,
                                accentBorder: CeptraTheme.accentWarm
                            )
                        )
                    }

                    if tab.isExecutableTestFile || tab.language == "javascript" || tab.language == "typescript" {
                        CeptraGlassDropdown(minWidth: 260, maxWidth: 340) { isOpen in
                            CeptraMenuPillLabel(
                                title: "Snippet",
                                titleFont: .system(size: 11, weight: .medium),
                                titleColor: CeptraTheme.textSecondary,
                                horizontalPadding: 8,
                                verticalPadding: 3,
                                cornerRadius: 6,
                                isOpen: isOpen
                            ) {
                                Image(systemName: "curlybraces.square")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(CeptraTheme.textSecondary)
                            }
                        } content: {
                            CeptraDropdownSectionHeader(title: "Insert Code Snippet")
                            ForEach(CodeSnippetItem.builtInSnippets) { snippet in
                                CeptraDropdownItem(
                                    title: snippet.title,
                                    subtitle: snippet.subtitle,
                                    systemImage: "curlybraces"
                                ) {
                                    appState.insertSnippet(snippet)
                                }
                            }
                        }
                        .fixedSize()
                        .help("Insert CodeceptJS Snippet")
                        .accessibilityLabel("Insert Code Snippet")
                    }

                    // Show execution button ONLY for CodeceptJS test suites and Gherkin feature files
                    if appState.isActiveTabExecutableTestFile {
                        Button {
                            appState.runActiveFile()
                        } label: {
                            Label("Run Test File", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CeptraTheme.success)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(
                            CeptraGlassButtonStyle(
                                cornerRadius: 6,
                                tint: CeptraTheme.success,
                                tintOpacity: 0.12,
                                accentBorder: CeptraTheme.success
                            )
                        )
                        .disabled(appState.isRunning)
                        .opacity(appState.isRunning ? 0.5 : 1)
                        .help("Run \(tab.name) (⌘⇧R)")
                    }
                }
                .padding(.trailing, 10)
            }
        }
        .frame(height: 34)
        .ceptraGlassBar(tint: CeptraTheme.sidebarBG, tintOpacity: 0.68, bottomHairline: true)
        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: hasNavigationHistory)
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

            Divider().overlay(CeptraTheme.border)

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

            Divider().overlay(CeptraTheme.border)

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
        .padding(16)
        .frame(width: 320)
        .presentationBackground(.ultraThinMaterial)
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
        .ceptraGlassSurface(
            cornerRadius: 999,
            tint: CeptraTheme.elevatedBG,
            tintOpacity: 0.68,
            accentBorder: isError ? CeptraTheme.failure : CeptraTheme.success,
            elevatedShadow: true
        )
    }
}
