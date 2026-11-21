import CeptraCore
import SwiftUI

struct MainStudioView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sidebarWidth: CGFloat = 280
    @State private var sidebarDragStartWidth: CGFloat = 280
    @State private var isResizingSidebar = false

    @State private var debugInspectorWidth: CGFloat = 320
    @State private var inspectorDragStartWidth: CGFloat = 320
    @State private var isResizingInspector = false

    @State private var consoleBodyHeight: CGFloat = 220
    @State private var consoleDragStartHeight: CGFloat = 220
    @State private var isResizingConsole = false

    @State private var splitVisualizerWidth: CGFloat = 420
    @State private var splitVisualizerDragStartWidth: CGFloat = 420
    @State private var isResizingSplitVisualizer = false

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
        .sheet(isPresented: $appState.showingNewFolderSheet) {
            NewFolderSheetView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingParallelRunSheet) {
            ParallelRunSheetView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingUpdateSheet) {
            UpdateSheetView()
                .environmentObject(appState)
        }
    }

    private var workspaceContent: some View {
        GeometryReader { rootGeo in
            let handleThickness = CeptraSplitResizeHandle.hitThickness
            let sidebarHandleW: CGFloat = appState.isSidebarVisible ? handleThickness : 0
            let availableRootW = max(0, rootGeo.size.width - sidebarHandleW)
            let minSidebarWidth: CGFloat = 235
            let maxSidebarWidth: CGFloat = max(minSidebarWidth, min(380, availableRootW * 0.36))
            let effectiveSidebarWidth = min(max(sidebarWidth, minSidebarWidth), maxSidebarWidth)
            let sidebarCursor: CeptraSplitResizeHandle.CursorDirection =
                effectiveSidebarWidth <= minSidebarWidth + 0.5
                    ? .onlyTrailingOrDown
                    : (effectiveSidebarWidth >= maxSidebarWidth - 0.5 ? .onlyLeadingOrUp : .both)

            HStack(spacing: 0) {
                SidebarExplorerView()
                    .frame(width: effectiveSidebarWidth)
                    .opacity(appState.isSidebarVisible ? 1 : 0)
                    .offset(x: appState.isSidebarVisible || reduceMotion ? 0 : -12)
                    .frame(width: appState.isSidebarVisible ? effectiveSidebarWidth : 0, alignment: .trailing)
                    .clipped()
                    .allowsHitTesting(appState.isSidebarVisible)
                    .accessibilityHidden(!appState.isSidebarVisible)

                if appState.isSidebarVisible {
                    CeptraSplitResizeHandle(
                        axis: .horizontal,
                        cursorDirection: sidebarCursor,
                        onDragStart: {
                            isResizingSidebar = true
                            sidebarDragStartWidth = effectiveSidebarWidth
                        },
                        onDragChanged: { delta in
                            sidebarWidth = min(max(sidebarDragStartWidth + delta, minSidebarWidth), maxSidebarWidth)
                        },
                        onDragEnd: {
                            isResizingSidebar = false
                        },
                        onDoubleClick: {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                                sidebarWidth = 280
                            }
                        }
                    )
                }

                GeometryReader { columnGeo in
                    let consoleHandleH: CGFloat = appState.isConsoleVisible ? handleThickness : 0
                    let minConsoleBody: CGFloat = 135
                    let maxConsoleBody = max(
                        minConsoleBody,
                        min(440, columnGeo.size.height - ConsoleDrawerView.headerHeight - consoleHandleH - 220)
                    )
                    let effectiveConsoleBody = min(max(consoleBodyHeight, minConsoleBody), maxConsoleBody)
                    let consoleCursor: CeptraSplitResizeHandle.CursorDirection =
                        effectiveConsoleBody <= minConsoleBody + 0.5
                            ? .onlyLeadingOrUp
                            : (effectiveConsoleBody >= maxConsoleBody - 0.5 ? .onlyTrailingOrDown : .both)

                    let inspectorHandleW: CGFloat = appState.isDebugInspectorVisible ? handleThickness : 0
                    let availableMainW = max(0, columnGeo.size.width - inspectorHandleW)
                    let minInspectorWidth: CGFloat = 270
                    let maxInspectorWidth: CGFloat = max(
                        minInspectorWidth,
                        min(420, min(availableMainW * 0.42, availableMainW - 360))
                    )
                    let effectiveInspectorWidth = min(max(debugInspectorWidth, minInspectorWidth), maxInspectorWidth)
                    let inspectorCursor: CeptraSplitResizeHandle.CursorDirection =
                        effectiveInspectorWidth <= minInspectorWidth + 0.5
                            ? .onlyLeadingOrUp
                            : (effectiveInspectorWidth >= maxInspectorWidth - 0.5 ? .onlyTrailingOrDown : .both)

                    VStack(spacing: 0) {
                        if appState.debugPhase.isActive {
                            HStack {
                                Spacer(minLength: 0)
                                DebugFloatingControlBar()
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(CeptraTheme.canvasBG)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .move(edge: .top).combined(with: .opacity)
                            )
                        }

                        HStack(spacing: 0) {
                            centerPane
                                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

                            if appState.isDebugInspectorVisible {
                                CeptraSplitResizeHandle(
                                    axis: .horizontal,
                                    cursorDirection: inspectorCursor,
                                    onDragStart: {
                                        isResizingInspector = true
                                        inspectorDragStartWidth = effectiveInspectorWidth
                                    },
                                    onDragChanged: { delta in
                                        debugInspectorWidth = min(max(inspectorDragStartWidth - delta, minInspectorWidth), maxInspectorWidth)
                                    },
                                    onDragEnd: {
                                        isResizingInspector = false
                                    },
                                    onDoubleClick: {
                                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                                            debugInspectorWidth = 320
                                        }
                                    }
                                )
                            }

                            DebugInspectorView()
                                .frame(width: effectiveInspectorWidth)
                                .opacity(appState.isDebugInspectorVisible ? 1 : 0)
                                .offset(x: appState.isDebugInspectorVisible || reduceMotion ? 0 : 12)
                                .frame(width: appState.isDebugInspectorVisible ? effectiveInspectorWidth : 0, alignment: .leading)
                                .clipped()
                                .allowsHitTesting(appState.isDebugInspectorVisible)
                                .accessibilityHidden(!appState.isDebugInspectorVisible)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(
                            isResizingInspector ? nil : CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion),
                            value: appState.isDebugInspectorVisible
                        )

                        if appState.isConsoleVisible {
                            CeptraSplitResizeHandle(
                                axis: .vertical,
                                cursorDirection: consoleCursor,
                                onDragStart: {
                                    isResizingConsole = true
                                    consoleDragStartHeight = effectiveConsoleBody
                                },
                                onDragChanged: { delta in
                                    consoleBodyHeight = min(max(consoleDragStartHeight - delta, minConsoleBody), maxConsoleBody)
                                },
                                onDragEnd: {
                                    isResizingConsole = false
                                },
                                onDoubleClick: {
                                    withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                                        consoleBodyHeight = 220
                                    }
                                }
                            )
                        }

                        ConsoleDrawerView(
                            bodyHeight: effectiveConsoleBody,
                            isResizing: isResizingConsole
                        )
                    }
                    .animation(
                        isResizingConsole ? nil : CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion),
                        value: appState.isConsoleVisible
                    )
                    .animation(
                        CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion),
                        value: appState.debugPhase.isActive
                    )
                }
            }
            .animation(
                isResizingSidebar ? nil : CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion),
                value: appState.isSidebarVisible
            )
        }
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
                            GeometryReader { splitGeo in
                                let availableSplit = max(0, splitGeo.size.width - CeptraSplitResizeHandle.hitThickness)
                                let preferredMinEditor: CGFloat = 340
                                let preferredMinVisual: CGFloat = 320
                                let splitBounds: (minVisual: CGFloat, maxVisual: CGFloat) = {
                                    if availableSplit >= preferredMinEditor + preferredMinVisual {
                                        let cappedMax = min(availableSplit - preferredMinEditor, availableSplit * 0.62)
                                        return (preferredMinVisual, max(preferredMinVisual, cappedMax))
                                    }
                                    // Balanced fallback when sidebar + debug inspector narrow the split area
                                    let safeVisualFloor = min(preferredMinVisual, max(240, availableSplit * 0.44))
                                    let safeEditorFloor = min(preferredMinEditor, max(240, availableSplit * 0.44))
                                    return (safeVisualFloor, max(safeVisualFloor, availableSplit - safeEditorFloor))
                                }()
                                let minVisual = splitBounds.minVisual
                                let maxVisual = splitBounds.maxVisual
                                let effectiveVisualWidth = min(max(splitVisualizerWidth, minVisual), maxVisual)
                                let splitCursor: CeptraSplitResizeHandle.CursorDirection = {
                                    if maxVisual - minVisual <= 0.5 { return .both }
                                    if effectiveVisualWidth <= minVisual + 0.5 { return .onlyLeadingOrUp }
                                    if effectiveVisualWidth >= maxVisual - 0.5 { return .onlyTrailingOrDown }
                                    return .both
                                }()

                                HStack(spacing: 0) {
                                    editorSurface(for: activeTab)
                                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

                                    CeptraSplitResizeHandle(
                                        axis: .horizontal,
                                        cursorDirection: splitCursor,
                                        onDragStart: {
                                            isResizingSplitVisualizer = true
                                            splitVisualizerDragStartWidth = effectiveVisualWidth
                                        },
                                        onDragChanged: { delta in
                                            splitVisualizerWidth = min(max(splitVisualizerDragStartWidth - delta, minVisual), maxVisual)
                                        },
                                        onDragEnd: {
                                            isResizingSplitVisualizer = false
                                        },
                                        onDoubleClick: {
                                            withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                                                splitVisualizerWidth = 420
                                            }
                                        }
                                    )

                                    FlowVisualizerView(
                                        file: appState.activeWorkspaceFile,
                                        features: appState.activeFeaturesForCurrentTab
                                    )
                                    .frame(width: effectiveVisualWidth)
                                }
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
            foldActionTrigger: appState.editorFoldActionTrigger,
            foldAction: appState.pendingEditorFoldAction,
            onNavigate: { target, fromLine in
                appState.navigateToImportTarget(target, fromLine: fromLine)
            },
            breakpointsByLine: appState.breakpointsByLine(forFilePath: tab.filePath),
            pausedLine: appState.activePausedLine(forFilePath: tab.filePath),
            onToggleBreakpoint: { line in
                appState.toggleBreakpoint(filePath: tab.filePath, line: line)
            },
            onEditBreakpoint: { bp in
                appState.updateBreakpoint(bp)
            },
            onRemoveBreakpoint: { id in
                appState.removeBreakpoint(id: id)
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
    @State private var leadingTrafficLightReserve: CGFloat = 76

    var body: some View {
        HStack(spacing: 8) {
            if appState.workspace != nil {
                Button {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
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
                    maxTitleWidth: 155,
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
                        maxTitleWidth: 155,
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

                // Runtime (Node vs Bun) & Console Target (Built-in vs System Console) Switcher
                let toolchain = appState.resolvedToolchain
                let runtime = appState.settings.jsRuntime
                let runtimeAvailable = toolchain?.isActiveRuntimeAvailable ?? true
                let runtimeAccent = runtime == .bun ? CeptraTheme.accentWarm : CeptraTheme.success
                CeptraGlassDropdown(minWidth: 270, maxWidth: 350) { isOpen in
                    CeptraMenuPillLabel(
                        title: appState.isSystemConsoleMode ? "\(runtime.shortName) · Sys" : runtime.shortName,
                        titleFont: .system(size: 11, weight: .medium, design: .monospaced),
                        titleColor: runtimeAvailable ? CeptraTheme.textPrimary : CeptraTheme.warning,
                        accentBorder: appState.isSystemConsoleMode ? CeptraTheme.cyan : (runtime == .bun ? CeptraTheme.accentWarm : nil),
                        tint: appState.isSystemConsoleMode ? CeptraTheme.cyan : runtimeAccent,
                        tintOpacity: 0.12,
                        horizontalPadding: 8,
                        verticalPadding: 5,
                        cornerRadius: 8,
                        isOpen: isOpen
                    ) {
                        Circle()
                            .fill(runtimeAvailable ? runtimeAccent : CeptraTheme.warning)
                            .frame(width: 6.5, height: 6.5)
                    }
                } content: {
                    CeptraDropdownSectionHeader(title: "JavaScript Runtime")
                    CeptraDropdownItem(
                        title: "Node.js",
                        subtitle: toolchain?.nodePath ?? "Not found in PATH",
                        systemImage: "hexagon.fill",
                        iconColor: toolchain?.nodePath != nil ? CeptraTheme.success : CeptraTheme.warning,
                        isSelected: runtime == .node,
                        isMonospaced: false
                    ) {
                        appState.setJSRuntime(.node)
                    }
                    CeptraDropdownItem(
                        title: "Bun",
                        subtitle: toolchain?.bunPath ?? "Not found — install bun or set path in Settings",
                        systemImage: "bolt.fill",
                        iconColor: toolchain?.bunPath != nil ? CeptraTheme.accentWarm : CeptraTheme.warning,
                        isSelected: runtime == .bun,
                        isMonospaced: false
                    ) {
                        appState.setJSRuntime(.bun)
                    }

                    CeptraDropdownDivider()
                    CeptraDropdownSectionHeader(title: "Console Target")
                    CeptraDropdownItem(
                        title: "Built-in Console",
                        subtitle: "Live steps, scenario badges & Time-Travel reports",
                        systemImage: "rectangle.bottomthird.inset.filled",
                        iconColor: CeptraTheme.accent,
                        isSelected: !appState.isSystemConsoleMode
                    ) {
                        appState.setConsoleExecutionMode(.builtIn)
                    }
                    CeptraDropdownItem(
                        title: "System Console (\(appState.activeTerminalDisplayName))",
                        subtitle: "Native TTY colors, login shell & interactive prompt",
                        systemImage: "terminal",
                        iconColor: CeptraTheme.cyan,
                        isSelected: appState.isSystemConsoleMode
                    ) {
                        appState.setConsoleExecutionMode(.systemTerminal)
                    }

                    CeptraDropdownDivider()
                    CeptraDropdownItem(
                        title: "Open Workspace in \(appState.activeTerminalDisplayName)",
                        subtitle: ws.rootURL.lastPathComponent,
                        systemImage: "arrow.up.forward.app",
                        iconColor: CeptraTheme.cyan,
                        shortcut: "⌘⇧T"
                    ) {
                        appState.openWorkspaceInSystemTerminal()
                    }
                }
                .fixedSize()
                .help("Runtime: \(runtime.displayName) (\(toolchain?.activeRuntimePath ?? "not found")) • Console: \(appState.isSystemConsoleMode ? appState.activeTerminalDisplayName : "Built-in")")
                .accessibilityLabel("Runtime and Console Switcher")
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

                        Button {
                            if appState.isActiveTabExecutableTestFile {
                                appState.debugActiveFile()
                            } else {
                                appState.debug(mode: .runAll)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "ladybug.fill")
                                    .font(.system(size: 10))
                                Text("Debug")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(CeptraTheme.accentWarm)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(
                            CeptraGlassButtonStyle(
                                cornerRadius: 7,
                                tint: CeptraTheme.accentWarm,
                                tintOpacity: 0.16,
                                accentBorder: CeptraTheme.accentWarm
                            )
                        )
                        .help(appState.isActiveTabExecutableTestFile ? "Debug Current Test File (⌘⇧B)" : "Debug All Tests")

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
                                systemImage: "checklist",
                                shortcut: "⌘⇧D"
                            ) {
                                appState.run(mode: .dryRun(relativePath: nil))
                            }
                            CeptraDropdownItem(
                                title: "Re-run Last Failed",
                                systemImage: "arrow.counterclockwise.circle",
                                iconColor: CeptraTheme.warning
                            ) {
                                appState.run(mode: .runLastFailed)
                            }

                            CeptraDropdownDivider()
                            CeptraDropdownSectionHeader(title: "Parallel & Multi-Suite")
                            CeptraDropdownItem(
                                title: "Run Workers",
                                subtitle: "\(appState.runOptions.workerCount)x \(appState.runOptions.workerStrategy.rawValue) (codeceptjs run-workers)",
                                systemImage: "cpu",
                                iconColor: CeptraTheme.cyan,
                                shortcut: "⌘⇧W"
                            ) {
                                appState.runWorkersWithCurrentOptions()
                            }
                            CeptraDropdownItem(
                                title: "Configure Workers…",
                                subtitle: "Strategy, --serial, --last-failed",
                                systemImage: "slider.horizontal.3"
                            ) {
                                appState.presentParallelRunSheet(tab: .workers)
                            }
                            CeptraDropdownItem(
                                title: "Run Multiple — All Suites",
                                subtitle: "codeceptjs run-multiple --all",
                                systemImage: "square.stack.3d.up",
                                iconColor: CeptraTheme.success,
                                shortcut: "⌘⇧M"
                            ) {
                                appState.run(mode: .runMultiple(suites: [], runAll: true))
                            }
                            if let suites = appState.workspace?.config.multipleSuites, !suites.isEmpty {
                                ForEach(suites) { suite in
                                    CeptraDropdownItem(
                                        title: "Run Multiple: \(suite.name)",
                                        subtitle: suite.browsers.isEmpty ? "all configured browsers" : suite.browsers.joined(separator: ", "),
                                        systemImage: "play.square.stack",
                                        iconColor: CeptraTheme.accent,
                                        isMonospaced: true
                                    ) {
                                        appState.run(mode: .runMultiple(suites: [suite.name], runAll: false))
                                    }
                                }
                            }
                            CeptraDropdownItem(
                                title: "Configure Multiple Run…",
                                subtitle: "Select suites & suite:browser targets",
                                systemImage: "square.stack.3d.up.fill"
                            ) {
                                appState.presentParallelRunSheet(tab: .multiple)
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
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
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

                    Button {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.isDebugInspectorVisible.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: appState.debugPhase.isActive ? "ladybug.fill" : "ladybug")
                                .font(.system(size: 11.5))
                            if !appState.breakpoints.isEmpty {
                                Text("\(appState.breakpoints.count)")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .monospacedDigit()
                            }
                        }
                        .foregroundStyle(
                            appState.debugPhase.isActive
                                ? CeptraTheme.accentWarm
                                : (appState.isDebugInspectorVisible ? CeptraTheme.accent : CeptraTheme.textSecondary)
                        )
                        .padding(.horizontal, appState.breakpoints.isEmpty ? 0 : 7)
                        .frame(minWidth: 28, minHeight: 26)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(
                        CeptraGlassButtonStyle(
                            cornerRadius: 7,
                            tint: appState.debugPhase.isActive ? CeptraTheme.accentWarm : CeptraTheme.panelBG,
                            tintOpacity: appState.debugPhase.isActive ? 0.16 : 0.56,
                            accentBorder: appState.debugPhase.isActive
                                ? CeptraTheme.accentWarm
                                : (appState.isDebugInspectorVisible ? CeptraTheme.accent : nil),
                            isActive: appState.isDebugInspectorVisible
                        )
                    )
                    .help("Toggle Debug Inspector")
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
        .padding(.leading, leadingTrafficLightReserve)
        .padding(.trailing, 14)
        .frame(height: 44)
        .background(
            CeptraWindowTitlebarDragArea { newReserve in
                withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                    leadingTrafficLightReserve = newReserve
                }
            }
        )
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

private struct TabWidthPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TabDragPointerModifier: ViewModifier {
    let isDragging: Bool
    @State private var isLegacyCursorPushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(isDragging ? .grabActive : nil)
        } else {
            content
                .onChange(of: isDragging) { _, active in
                    syncLegacyCursor(active: active)
                }
                .onDisappear {
                    syncLegacyCursor(active: false)
                }
        }
    }

    private func syncLegacyCursor(active: Bool) {
        if active && !isLegacyCursorPushed {
            NSCursor.closedHand.push()
            isLegacyCursorPushed = true
        } else if !active && isLegacyCursorPushed {
            NSCursor.pop()
            isLegacyCursorPushed = false
        }
    }
}

private struct EditorTabBar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var activeTabNamespace
    @State private var hoveredTabPath: String?
    @State private var hoveredClosePath: String?
    @State private var tabWidths: [String: CGFloat] = [:]

    // Direct-manipulation horizontal rail drag state
    @State private var draggingTabPath: String?
    @State private var dragOriginIndex: Int?
    @State private var dragTargetIndex: Int?
    @State private var dragTranslationX: CGFloat = 0

    // Post-drop settle glide state (runs after atomic array commit)
    @State private var settlingTabPath: String?
    @State private var settlingOffsetX: CGFloat = 0
    @State private var settlingToken: UUID?

    private static let railCoordinateSpace = "EditorTabRail"
    private static let tabSpacing: CGFloat = 3
    private static let railHorizontalPadding: CGFloat = 4
    private static let dragActivationDistance: CGFloat = 5
    private static let fallbackTabWidth: CGFloat = 120

    private var hasNavigationHistory: Bool {
        appState.canNavigateBack || appState.canNavigateForward
    }

    private var orderedTabWidths: [Double] {
        appState.openTabs.map { Double(tabWidths[$0.filePath] ?? Self.fallbackTabWidth) }
    }

    private var indexByPath: [String: Int] {
        Dictionary(uniqueKeysWithValues: appState.openTabs.enumerated().map { ($1.filePath, $0) })
    }

    private var dropSlotIndicatorRect: (minX: CGFloat, width: CGFloat)? {
        guard let draggingPath = draggingTabPath,
              let originIndex = dragOriginIndex,
              let targetIndex = dragTargetIndex,
              appState.openTabs.indices.contains(originIndex) else {
            return nil
        }
        let widths = orderedTabWidths
        let minX = TabReorderEngine.targetSlotMinX(
            originIndex: originIndex,
            targetIndex: targetIndex,
            widths: widths,
            spacing: Double(Self.tabSpacing),
            leadingPadding: Double(Self.railHorizontalPadding)
        )
        let width = tabWidths[draggingPath] ?? Self.fallbackTabWidth
        return (CGFloat(minX), width)
    }

    var body: some View {
        let currentIndexByPath = indexByPath

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

            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .leading) {
                        // Recessed target drop-slot indicator behind sliding tabs
                        if let slot = dropSlotIndicatorRect {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(CeptraTheme.accent.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(
                                            CeptraTheme.accent.opacity(0.32),
                                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                                        )
                                )
                                .frame(width: slot.width, height: 26)
                                .offset(x: slot.minX)
                                .animation(
                                    CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion),
                                    value: dragTargetIndex
                                )
                                .allowsHitTesting(false)
                                .zIndex(0)
                        }

                        HStack(spacing: Self.tabSpacing) {
                            ForEach(appState.openTabs) { tab in
                                let tabIndex = currentIndexByPath[tab.filePath] ?? 0
                                tabPill(for: tab, index: tabIndex)
                                    .id(tab.filePath)
                            }
                        }
                        .padding(.horizontal, Self.railHorizontalPadding)
                    }
                    .coordinateSpace(name: Self.railCoordinateSpace)
                }
                .onPreferenceChange(TabWidthPreferenceKey.self) { widths in
                    if tabWidths != widths {
                        tabWidths = widths
                    }
                }
                .onChange(of: appState.activeTabPath) { _, newPath in
                    guard let newPath, draggingTabPath == nil else { return }
                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                        scrollProxy.scrollTo(newPath, anchor: .center)
                    }
                }
                .onChange(of: dragTargetIndex) { _, newTarget in
                    guard draggingTabPath != nil,
                          let newTarget,
                          appState.openTabs.indices.contains(newTarget) else { return }
                    let anchorPath = appState.openTabs[newTarget].filePath
                    withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                        scrollProxy.scrollTo(anchorPath)
                    }
                }
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

                    if appState.workspaceMode == .code || appState.workspaceMode == .split {
                        HStack(spacing: 4) {
                            Button {
                                appState.triggerEditorFold(.collapseAll)
                            } label: {
                                Image(systemName: "rectangle.compress.vertical")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(CeptraTheme.textSecondary)
                                    .frame(width: 24, height: 22)
                            }
                            .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 6, tint: CeptraTheme.panelBG, tintOpacity: 0.48))
                            .help("Collapse All Blocks (⌘⌥⇧[)")

                            Button {
                                appState.triggerEditorFold(.expandAll)
                            } label: {
                                Image(systemName: "rectangle.expand.vertical")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(CeptraTheme.textSecondary)
                                    .frame(width: 24, height: 22)
                            }
                            .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 6, tint: CeptraTheme.panelBG, tintOpacity: 0.48))
                            .help("Expand All Blocks (⌘⌥⇧])")
                        }
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
                            appState.debugActiveFile()
                        } label: {
                            Image(systemName: "ladybug.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(CeptraTheme.accentWarm)
                                .frame(width: 24, height: 22)
                        }
                        .buttonStyle(
                            CeptraGlassButtonStyle(
                                cornerRadius: 6,
                                tint: CeptraTheme.accentWarm,
                                tintOpacity: 0.14,
                                accentBorder: CeptraTheme.accentWarm
                            )
                        )
                        .disabled(appState.isRunning)
                        .opacity(appState.isRunning ? 0.5 : 1)
                        .help("Debug Current Test File (⌘⇧B)")

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
        .modifier(TabDragPointerModifier(isDragging: draggingTabPath != nil))
        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: hasNavigationHistory)
        .onChange(of: appState.openTabs.map(\.filePath)) { _, newPaths in
            if draggingTabPath != nil {
                resetDragState()
            }
            if let settling = settlingTabPath, !newPaths.contains(settling) {
                settlingToken = nil
                settlingTabPath = nil
                settlingOffsetX = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if draggingTabPath != nil {
                resetDragState()
            }
        }
    }

    @ViewBuilder
    private func tabPill(for tab: OpenDocumentTab, index: Int) -> some View {
        let isActive = tab.filePath == appState.activeTabPath
        let isDragged = draggingTabPath == tab.filePath
        let isSettling = settlingTabPath == tab.filePath
        let isAnyDragging = draggingTabPath != nil
        let isHovered = !isAnyDragging && hoveredTabPath == tab.filePath
        let isCloseHovered = !isAnyDragging && hoveredClosePath == tab.filePath

        let siblingDisplacement: CGFloat = {
            guard let draggingPath = draggingTabPath,
                  let originIndex = dragOriginIndex,
                  let targetIndex = dragTargetIndex,
                  !isDragged else {
                return 0
            }
            let draggedWidth = Double(tabWidths[draggingPath] ?? Self.fallbackTabWidth)
            return CGFloat(
                TabReorderEngine.displacement(
                    forOriginalIndex: index,
                    originIndex: originIndex,
                    targetIndex: targetIndex,
                    draggedWidth: draggedWidth,
                    spacing: Double(Self.tabSpacing)
                )
            )
        }()

        let horizontalOffset: CGFloat = {
            if isDragged {
                return dragTranslationX
            }
            if isSettling {
                return settlingOffsetX
            }
            return siblingDisplacement
        }()

        let tabZIndex: Double = {
            if isDragged { return 100 }
            if isSettling { return 50 }
            if isActive { return 10 }
            return 1
        }()

        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: tab.category.symbolName)
                    .font(.system(size: 10))
                    .foregroundStyle(tab.isExecutableTestFile ? CeptraTheme.accent : CeptraTheme.textMuted)
                Text(tab.name)
                    .font(.system(size: 11.5, weight: (isActive || isDragged) ? .semibold : .regular))
                    .foregroundStyle(
                        (isActive || isDragged)
                            ? CeptraTheme.textPrimary
                            : (isHovered ? CeptraTheme.textPrimary.opacity(0.88) : CeptraTheme.textSecondary)
                    )
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
            .help(appState.openTabs.count > 1 ? "\(tab.relativePath) — Drag to reorder" : tab.relativePath)
            .gesture(tabDragGesture(for: tab, index: index))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tab.isDirty ? "\(tab.name), unsaved changes" : tab.name)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction {
                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                    appState.switchTab(to: tab.filePath)
                }
            }
            .accessibilityAction(named: Text("Move Tab Left")) {
                guard index > 0 else { return }
                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                    _ = appState.moveTab(filePath: tab.filePath, toIndex: index - 1)
                }
            }
            .accessibilityAction(named: Text("Move Tab Right")) {
                guard index < appState.openTabs.count - 1 else { return }
                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                    _ = appState.moveTab(filePath: tab.filePath, toIndex: index + 1)
                }
            }

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
                    .fill(CeptraTheme.canvasBG.opacity(isDragged ? 0.98 : 0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                isDragged
                                    ? CeptraTheme.accentSpecularRim(CeptraTheme.accent)
                                    : CeptraTheme.specularRimGradient,
                                lineWidth: isDragged ? 0.9 : 0.7
                            )
                    )
                    .matchedGeometryEffect(id: "active-editor-tab-bg", in: activeTabNamespace)
            } else if isDragged {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(CeptraTheme.elevatedBG.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(CeptraTheme.accentSpecularRim(CeptraTheme.accent), lineWidth: 0.9)
                    )
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
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TabWidthPreferenceKey.self,
                    value: [tab.filePath: proxy.size.width]
                )
            }
        )
        .scaleEffect(isDragged ? (reduceMotion ? 1.0 : 1.02) : 1.0)
        .shadow(
            color: isDragged ? Color.black.opacity(0.45) : .clear,
            radius: isDragged ? 8 : 0,
            y: isDragged ? 3 : 0
        )
        .animation(
            CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion),
            value: isDragged
        )
        .padding(.vertical, 2)
        .offset(x: horizontalOffset)
        .zIndex(tabZIndex)
        .animation(
            isAnyDragging && !isDragged
                ? CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)
                : nil,
            value: siblingDisplacement
        )
        .onHover { hovering in
            guard draggingTabPath == nil else { return }
            withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                hoveredTabPath = hovering ? tab.filePath : (hoveredTabPath == tab.filePath ? nil : hoveredTabPath)
            }
        }
    }

    private func tabDragGesture(for tab: OpenDocumentTab, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.railCoordinateSpace))
            .onChanged { value in
                let dx = value.location.x - value.startLocation.x

                // Begin drag once horizontal movement exceeds threshold and at least 2 tabs exist.
                if draggingTabPath != tab.filePath {
                    guard draggingTabPath == nil,
                          appState.openTabs.count > 1,
                          abs(dx) >= Self.dragActivationDistance else {
                        return
                    }
                    // Cancel any in-flight settle glide before starting a fresh drag.
                    settlingToken = nil
                    settlingTabPath = nil
                    settlingOffsetX = 0
                    hoveredTabPath = nil
                    hoveredClosePath = nil
                    draggingTabPath = tab.filePath
                    dragOriginIndex = index
                    dragTargetIndex = index
                }

                guard let originIndex = dragOriginIndex,
                      let currentTarget = dragTargetIndex else {
                    return
                }

                let widths = orderedTabWidths
                let clampedX = TabReorderEngine.clampedTranslation(
                    rawTranslation: Double(dx),
                    originIndex: originIndex,
                    widths: widths,
                    spacing: Double(Self.tabSpacing)
                )
                dragTranslationX = CGFloat(clampedX)

                let nextTarget = TabReorderEngine.targetIndex(
                    forOriginIndex: originIndex,
                    currentTargetIndex: currentTarget,
                    translationX: clampedX,
                    widths: widths,
                    spacing: Double(Self.tabSpacing)
                )
                if nextTarget != currentTarget {
                    dragTargetIndex = nextTarget
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                }
            }
            .onEnded { value in
                if draggingTabPath == tab.filePath {
                    commitTabDrag(for: tab)
                } else {
                    let dx = value.location.x - value.startLocation.x
                    let dy = value.location.y - value.startLocation.y
                    if abs(dx) < 16 && abs(dy) < 24 {
                        settlingToken = nil
                        settlingTabPath = nil
                        settlingOffsetX = 0
                        withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                            appState.switchTab(to: tab.filePath)
                        }
                    }
                }
            }
    }

    private func commitTabDrag(for tab: OpenDocumentTab) {
        guard let originIndex = dragOriginIndex,
              let targetIndex = dragTargetIndex,
              appState.openTabs.indices.contains(originIndex) else {
            resetDragState()
            return
        }

        let widths = orderedTabWidths
        let originalSlots = TabReorderEngine.slotFrames(
            widths: widths,
            spacing: Double(Self.tabSpacing),
            leadingPadding: Double(Self.railHorizontalPadding)
        )
        let currentVisualMinX = originalSlots[originIndex].minX + Double(dragTranslationX)
        let restingMinX = TabReorderEngine.targetSlotMinX(
            originIndex: originIndex,
            targetIndex: targetIndex,
            widths: widths,
            spacing: Double(Self.tabSpacing),
            leadingPadding: Double(Self.railHorizontalPadding)
        )
        let remainingDelta = CGFloat(currentVisualMinX - restingMinX)

        // Atomically commit the new order and hand off visual continuity to `settlingOffsetX`
        // with animations disabled so siblings snap into their new layout slots at 0 visual delta.
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            if targetIndex != originIndex {
                appState.moveTab(filePath: tab.filePath, toIndex: targetIndex)
            }
            draggingTabPath = nil
            dragOriginIndex = nil
            dragTargetIndex = nil
            dragTranslationX = 0
            if abs(remainingDelta) > 0.5 {
                settlingTabPath = tab.filePath
                settlingOffsetX = remainingDelta
            } else {
                settlingToken = nil
                settlingTabPath = nil
                settlingOffsetX = 0
            }
        }

        guard abs(remainingDelta) > 0.5 else { return }
        let settleID = UUID()
        settlingToken = settleID
        DispatchQueue.main.async {
            guard settlingToken == settleID else { return }
            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                settlingOffsetX = 0
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            if settlingToken == settleID {
                settlingToken = nil
                settlingTabPath = nil
                settlingOffsetX = 0
            }
        }
    }

    private func resetDragState() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            draggingTabPath = nil
            dragOriginIndex = nil
            dragTargetIndex = nil
            dragTranslationX = 0
            settlingToken = nil
            settlingTabPath = nil
            settlingOffsetX = 0
        }
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

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Runtime:")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 58, alignment: .leading)
                    Picker(
                        "",
                        selection: Binding(
                            get: { appState.settings.jsRuntime },
                            set: { appState.setJSRuntime($0) }
                        )
                    ) {
                        ForEach(JSRuntimeKind.allCases) { rt in
                            Text(rt.displayName).tag(rt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                HStack(spacing: 8) {
                    Text("Console:")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 58, alignment: .leading)
                    Picker(
                        "",
                        selection: Binding(
                            get: { appState.settings.consoleExecutionMode },
                            set: { appState.setConsoleExecutionMode($0) }
                        )
                    ) {
                        Text("Built-in").tag(ConsoleExecutionMode.builtIn)
                        Text(appState.activeTerminalDisplayName).tag(ConsoleExecutionMode.systemTerminal)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Divider().overlay(CeptraTheme.border)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show Steps (--steps)", isOn: $appState.runOptions.showSteps)
                Toggle("Debug Output (--debug)", isOn: $appState.runOptions.debug)
                Toggle("Verbose Logging (--verbose)", isOn: $appState.runOptions.verbose)
                Toggle("Enable AI Assistant (--ai)", isOn: $appState.runOptions.aiEnabled)
                Toggle("Bail on First Failure (--bail)", isOn: $appState.runOptions.bailOnFail)
                Toggle("Disable Timeouts (--no-timeouts)", isOn: $appState.runOptions.noTimeouts)
                Toggle("Capture Time-Travel Trace (DOM, Network, Shots)", isOn: $appState.runOptions.timeTravelTrace)
                    .disabled(appState.isSystemConsoleMode)
                Toggle(
                    appState.settings.jsRuntime == .bun
                        ? "ESM/CJS Compat (Node.js only — native in Bun)"
                        : "ESM/CJS Named-Export Compat (uuid, etc.)",
                    isOn: $appState.runOptions.esmCjsCompat
                )
                .disabled(appState.settings.jsRuntime == .bun)
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
                    HStack(spacing: 6) {
                        TextField("Regex or @tag", text: $appState.runOptions.grepPattern)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                        Toggle("Invert", isOn: $appState.runOptions.invertGrep)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10.5))
                            .help("Invert --grep matches (--invert)")
                    }
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
                GridRow {
                    Text("Serial:")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    TextField("Optional --serial pattern", text: $appState.runOptions.workerSerialPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                }
            }

            Divider().overlay(CeptraTheme.border)

            VStack(alignment: .leading, spacing: 8) {
                Text("Debug Mode")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accentWarm)

                Toggle("Headed Browser (HEADLESS=false)", isOn: $appState.runOptions.debugLaunchOptions.headedBrowser)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))

                HStack(spacing: 8) {
                    Text("Exceptions:")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Picker(
                        "",
                        selection: Binding(
                            get: { appState.runOptions.debugLaunchOptions.breakOnExceptions },
                            set: { appState.setExceptionBreakMode($0) }
                        )
                    ) {
                        ForEach(ExceptionBreakMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            Divider().overlay(CeptraTheme.border)

            HStack(spacing: 8) {
                Button {
                    appState.showingRunOptionsPopover = false
                    appState.presentParallelRunSheet(tab: .workers)
                } label: {
                    Label("run-workers…", systemImage: "cpu")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 7, tint: CeptraTheme.panelBG, tintOpacity: 0.56))

                Button {
                    appState.showingRunOptionsPopover = false
                    appState.presentParallelRunSheet(tab: .multiple)
                } label: {
                    Label("run-multiple…", systemImage: "square.stack.3d.up")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 7, tint: CeptraTheme.panelBG, tintOpacity: 0.56))
            }
        }
        .padding(16)
        .frame(width: 340)
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
