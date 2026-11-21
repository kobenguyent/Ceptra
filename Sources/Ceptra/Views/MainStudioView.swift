import AppKit
import CeptraCore
import SwiftUI

struct MainStudioView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sidebarWidth: CGFloat = 252
    @State private var sidebarDragStartWidth: CGFloat = 252
    @State private var isResizingSidebar = false

    @State private var rightInspectorWidth: CGFloat = 336
    @State private var inspectorDragStartWidth: CGFloat = 336
    @State private var isResizingInspector = false

    @State private var consoleBodyHeight: CGFloat = 190
    @State private var consoleDragStartHeight: CGFloat = 190
    @State private var isResizingConsole = false

    var body: some View {
        ZStack(alignment: .top) {
            CeptraTheme.frameBG.ignoresSafeArea()

            VStack(spacing: 0) {
                TopStudioBar()

                if appState.workspace == nil {
                    WelcomeView()
                        .transition(.opacity)
                } else {
                    threeWindowStage
                        .transition(.opacity)

                    if appState.isStatusBarVisible {
                        BottomModuleStatusStrip()
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(CeptraMotion.resolve(CeptraMotion.smooth, reduceMotion: reduceMotion), value: appState.workspace == nil)
            .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: appState.isStatusBarVisible)

            if let message = appState.bannerMessage {
                ToastBanner(message: message, isError: appState.bannerIsError)
                    .padding(.top, 48)
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
        .sheet(isPresented: $appState.showingCommandPalette) {
            CommandPaletteView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingReportsSheet) {
            VStack(spacing: 0) {
                HStack {
                    Label("Run History, Reports & Artifacts", systemImage: "chart.bar.doc.horizontal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Spacer()
                    Button("Done") {
                        appState.showingReportsSheet = false
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(CeptraTheme.sidebarBG)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CeptraTheme.border).frame(height: 1)
                }

                ReportsDashboardView()
                    .environmentObject(appState)
            }
            .frame(minWidth: 880, minHeight: 580)
        }
    }

    // MARK: - Three Soft-Edged Vertical Windows

    private var threeWindowStage: some View {
        GeometryReader { rootGeo in
            let outerPadding: CGFloat = 8
            let gapW: CGFloat = 8
            let usableW = max(0, rootGeo.size.width - outerPadding * 2)

            let minLeftW: CGFloat = 216
            let maxLeftW: CGFloat = max(minLeftW, min(360, usableW * 0.32))
            let effectiveLeftW = min(max(sidebarWidth, minLeftW), maxLeftW)
            let leftCursor: CeptraSplitResizeHandle.CursorDirection =
                effectiveLeftW <= minLeftW + 0.5
                    ? .onlyTrailingOrDown
                    : (effectiveLeftW >= maxLeftW - 0.5 ? .onlyLeadingOrUp : .both)

            let minRightW: CGFloat = 280
            let maxRightW: CGFloat = max(minRightW, min(480, usableW * 0.40))
            let effectiveRightW = min(max(rightInspectorWidth, minRightW), maxRightW)
            let rightCursor: CeptraSplitResizeHandle.CursorDirection =
                effectiveRightW <= minRightW + 0.5
                    ? .onlyLeadingOrUp
                    : (effectiveRightW >= maxRightW - 0.5 ? .onlyTrailingOrDown : .both)

            HStack(spacing: 0) {
                // WINDOW 1 (LEFT): Soft-Edged Smart Explorer
                SidebarExplorerView()
                    .ceptraPaneWindow(subtle: true)
                    .frame(width: effectiveLeftW)
                    .opacity(appState.isSidebarVisible ? 1 : 0)
                    .offset(x: appState.isSidebarVisible || reduceMotion ? 0 : -10)
                    .frame(width: appState.isSidebarVisible ? effectiveLeftW : 0, alignment: .trailing)
                    .clipped()
                    .allowsHitTesting(appState.isSidebarVisible)
                    .accessibilityHidden(!appState.isSidebarVisible)

                if appState.isSidebarVisible {
                    CeptraSplitResizeHandle(
                        axis: .horizontal,
                        cursorDirection: leftCursor,
                        isSoftGap: true,
                        onDragStart: {
                            isResizingSidebar = true
                            sidebarDragStartWidth = effectiveLeftW
                        },
                        onDragChanged: { delta in
                            sidebarWidth = min(max(sidebarDragStartWidth + delta, minLeftW), maxLeftW)
                        },
                        onDragEnd: {
                            isResizingSidebar = false
                        },
                        onDoubleClick: {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                                sidebarWidth = 252
                            }
                        }
                    )
                    .frame(width: gapW)
                }

                // WINDOW 2 (CENTER): Soft-Edged In-Window Tabs + Code Editor + Terminal Drawer
                centerSoftWindow
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

                if appState.isRightSidebarVisible {
                    CeptraSplitResizeHandle(
                        axis: .horizontal,
                        cursorDirection: rightCursor,
                        isSoftGap: true,
                        onDragStart: {
                            isResizingInspector = true
                            inspectorDragStartWidth = effectiveRightW
                        },
                        onDragChanged: { delta in
                            rightInspectorWidth = min(max(inspectorDragStartWidth - delta, minRightW), maxRightW)
                        },
                        onDragEnd: {
                            isResizingInspector = false
                        },
                        onDoubleClick: {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                                rightInspectorWidth = 336
                            }
                        }
                    )
                    .frame(width: gapW)
                }

                // WINDOW 3 (RIGHT): Soft-Edged Single-Slot Inspector (Replay · CodeceptUI · Outline · Debug)
                RightInspectorWindowView()
                    .frame(width: effectiveRightW)
                    .opacity(appState.isRightSidebarVisible ? 1 : 0)
                    .offset(x: appState.isRightSidebarVisible || reduceMotion ? 0 : 10)
                    .frame(width: appState.isRightSidebarVisible ? effectiveRightW : 0, alignment: .leading)
                    .clipped()
                    .allowsHitTesting(appState.isRightSidebarVisible)
                    .accessibilityHidden(!appState.isRightSidebarVisible)
            }
            .padding(.horizontal, outerPadding)
            .padding(.top, 2)
            .padding(.bottom, appState.isStatusBarVisible ? 6 : 8)
            .animation(
                isResizingSidebar ? nil : CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion),
                value: appState.isSidebarVisible
            )
            .animation(
                isResizingInspector ? nil : CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion),
                value: appState.isRightSidebarVisible
            )
        }
    }

    private var centerSoftWindow: some View {
        GeometryReader { colGeo in
            let handleH: CGFloat = appState.isConsoleVisible ? CeptraSplitResizeHandle.hitThickness : 0
            let minConsoleBody: CGFloat = 120
            let maxConsoleBody = max(
                minConsoleBody,
                min(420, colGeo.size.height - ConsoleDrawerView.headerHeight - handleH - 200)
            )
            let effectiveConsoleBody = min(max(consoleBodyHeight, minConsoleBody), maxConsoleBody)
            let consoleCursor: CeptraSplitResizeHandle.CursorDirection =
                effectiveConsoleBody <= minConsoleBody + 0.5
                    ? .onlyLeadingOrUp
                    : (effectiveConsoleBody >= maxConsoleBody - 0.5 ? .onlyTrailingOrDown : .both)

            VStack(spacing: 0) {
                EditorTabBar()

                if appState.debugPhase.isActive {
                    HStack {
                        Spacer(minLength: 0)
                        DebugFloatingControlBar()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CeptraTheme.canvasBG)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }

                if let activeTab = appState.activeTab {
                    editorSurface(for: activeTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyEditorPlaceholder
                }

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
                                consoleBodyHeight = 190
                            }
                        }
                    )

                    ConsoleDrawerView(
                        bodyHeight: effectiveConsoleBody,
                        isResizing: isResizingConsole
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ceptraPaneWindow(subtle: false)
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

    private func editorSurface(for tab: OpenDocumentTab) -> some View {
        let boundPath = tab.filePath
        let scenarioMarkers: [Int: (title: String, status: ExecutionStatus)] = {
            var map: [Int: (title: String, status: ExecutionStatus)] = [:]
            for feature in appState.activeFeaturesForCurrentTab {
                for sc in feature.scenarios {
                    map[sc.lineNumber] = (sc.cleanTitle, appState.statusForScenario(sc))
                }
            }
            return map
        }()

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
            scenariosByLine: scenarioMarkers,
            onToggleBreakpoint: { line in
                appState.toggleBreakpoint(filePath: tab.filePath, line: line)
            },
            onEditBreakpoint: { bp in
                appState.updateBreakpoint(bp)
            },
            onRemoveBreakpoint: { id in
                appState.removeBreakpoint(id: id)
            },
            onRunScenario: { scenarioTitle in
                let relPath = appState.activeWorkspaceFile?.relativePath ?? tab.relativePath
                appState.run(mode: .runScenario(relativePath: relPath, scenarioTitle: scenarioTitle))
            },
            onCursorChanged: { line, col in
                if appState.cursorLine != line || appState.cursorColumn != col {
                    appState.cursorLine = line
                    appState.cursorColumn = col
                }
            }
        )
    }

    private var emptyEditorPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(CeptraTheme.textMuted)
            Text("Select a test suite, feature, or page object")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(CeptraTheme.textSecondary)
            HStack(spacing: 8) {
                Button("Quick Open (⌘P)") {
                    appState.showingCommandPalette = true
                }
                .buttonStyle(.bordered)

                Button("New File…") {
                    appState.presentNewFileSheet(inDirectory: appState.activeFileParentRelativeDirectory)
                }
                .buttonStyle(.borderedProminent)
                .tint(CeptraTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CeptraTheme.canvasBG)
    }
}

// MARK: - Calm Static 40pt Titlebar (Zero Dynamic Header Button Bloat)

private struct TopStudioBar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var leadingTrafficLightReserve: CGFloat = 76
    @State private var showingRunMenu = false

    var body: some View {
        HStack(spacing: 8) {
            // Left: Left Sidebar Toggle + Clean projectName › activeFile Breadcrumb
            if appState.workspace != nil {
                CeptraTitlebarIconButton(
                    systemImage: "sidebar.leading",
                    isActive: appState.isSidebarVisible,
                    helpText: "Toggle Explorer Sidebar (⌘B)",
                    accessibilityLabelText: "Toggle Explorer Sidebar"
                ) {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                        appState.toggleLeftSidebar()
                    }
                }
            }

            HStack(spacing: 6) {
                CeptraGlassDropdown(minWidth: 255, maxWidth: 320) { _ in
                    Text(appState.workspace?.config.projectName ?? "Ceptra")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                            title: "Select Custom Config (-c)…",
                            systemImage: "gearshape",
                            shortcut: "⌘⇧C"
                        ) {
                            appState.selectCustomConfigPanel()
                        }
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

                if let activeTab = appState.activeTab {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textMuted)

                    Button {
                        appState.showingCommandPalette = true
                    } label: {
                        Text(activeTab.name)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Quick Jump / Command Palette (⌘K / ⌘P)")
                }
            }

            Spacer(minLength: 12)

            // Right: Primary ▶ Run ▾ + Hairline + Strictly 3 Static 28×26 Icons (>_ · ◨ · ⊞)
            if appState.workspace != nil {
                HStack(spacing: 6) {
                    runSplitPill

                    Rectangle()
                        .fill(CeptraTheme.borderStrong)
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 2)

                    // 1. Terminal & Logs Toggle
                    CeptraTitlebarIconButton(
                        systemImage: "terminal",
                        isActive: appState.isConsoleVisible,
                        showEmeraldIndicator: true,
                        helpText: "Toggle Terminal & Logs (⌘J)",
                        accessibilityLabelText: "Toggle Terminal and Logs"
                    ) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.toggleTerminal()
                        }
                    }

                    // 2. Right Sidebar Toggle
                    CeptraTitlebarIconButton(
                        systemImage: "sidebar.trailing",
                        isActive: appState.isRightSidebarVisible,
                        helpText: "Toggle Right Sidebar (⌘⌥B)",
                        accessibilityLabelText: "Toggle Right Sidebar"
                    ) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.toggleRightSidebar()
                        }
                    }

                    // 3. Tools & Modules Popover (Never spawns extra header icons!)
                    CeptraTitlebarIconButton(
                        systemImage: "square.grid.2x2",
                        isActive: appState.showingToolsPopover,
                        helpText: "Tools & Modules",
                        accessibilityLabelText: "Tools and Modules"
                    ) {
                        appState.showingToolsPopover.toggle()
                    }
                    .popover(isPresented: $appState.showingToolsPopover, arrowEdge: .bottom) {
                        ToolsControlPopover()
                            .environmentObject(appState)
                    }
                }
            }
        }
        .padding(.leading, leadingTrafficLightReserve)
        .padding(.trailing, 12)
        .frame(height: 40)
        .background(
            CeptraWindowTitlebarDragArea { newReserve in
                withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                    leadingTrafficLightReserve = newReserve
                }
            }
        )
        .popover(isPresented: $appState.showingRunOptionsPopover, arrowEdge: .bottom) {
            RunOptionsPopover()
                .environmentObject(appState)
        }
    }

    private var runSplitPill: some View {
        let isRunning = appState.isRunning
        let fill = isRunning ? CeptraTheme.failure : CeptraTheme.success
        let fg: Color = isRunning ? .white : Color(red: 0.02, green: 0.12, blue: 0.07)

        return HStack(spacing: 0) {
            Button {
                if isRunning {
                    appState.stopActiveRun()
                } else if appState.isActiveTabExecutableTestFile {
                    appState.runActiveFile()
                } else {
                    appState.run(mode: .runAll)
                }
            } label: {
                HStack(spacing: 5) {
                    if isRunning {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8.5, weight: .bold))
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                    }
                    Text(isRunning ? "Stop" : "Run")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(fg)
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRunning ? "Stop Running Tests (⌘.)" : (appState.isActiveTabExecutableTestFile ? "Run Active Test File (⌘⇧R)" : "Run All Tests (⌘R)"))

            Rectangle()
                .fill(Color.black.opacity(0.18))
                .frame(width: 1, height: 15)

            Button {
                showingRunMenu.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(fg)
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Run Modes, Workers, Multiple, Debug & Options")
            .popover(isPresented: $showingRunMenu, arrowEdge: .bottom) {
                RunSplitMenuPopover(isPresented: $showingRunMenu)
                    .environmentObject(appState)
            }
        }
        .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: fill.opacity(0.22), radius: 5, y: 1.5)
    }
}

// MARK: - Run Split Menu Popover (▶ Run ▾)

private struct RunSplitMenuPopover: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                CeptraDropdownSectionHeader(title: "Run Modes")
                if appState.isActiveTabExecutableTestFile {
                    menuRow("Run Active Test File", icon: "play.circle", color: CeptraTheme.success, shortcut: "⌘⇧R") {
                        appState.runActiveFile()
                    }
                }
                menuRow("Run All Tests", icon: "play.fill", color: CeptraTheme.success, shortcut: "⌘R") {
                    appState.run(mode: .runAll)
                }
                menuRow("Re-run Last Failed", icon: "arrow.counterclockwise.circle", color: CeptraTheme.warning) {
                    appState.run(mode: .runLastFailed)
                }
                menuRow("Dry Run (Validate & List)", icon: "checklist", shortcut: "⌘⇧D") {
                    appState.run(mode: .dryRun(relativePath: nil))
                }

                CeptraDropdownDivider()
                CeptraDropdownSectionHeader(title: "Debug & Parallel")
                menuRow(
                    appState.isActiveTabExecutableTestFile ? "Debug Active Test File" : "Debug All Tests",
                    icon: "ladybug.fill",
                    color: CeptraTheme.accentWarm,
                    shortcut: "⌘⇧B"
                ) {
                    if appState.isActiveTabExecutableTestFile {
                        appState.debugActiveFile()
                    } else {
                        appState.debug(mode: .runAll)
                    }
                }
                menuRow(
                    "Run Workers (\(appState.runOptions.workerCount)× \(appState.runOptions.workerStrategy.rawValue))",
                    icon: "cpu",
                    color: CeptraTheme.cyan,
                    shortcut: "⌘⇧W"
                ) {
                    appState.runWorkersWithCurrentOptions()
                }
                menuRow("Configure Workers…", icon: "slider.horizontal.3") {
                    appState.presentParallelRunSheet(tab: .workers)
                }
                menuRow("Run Multiple — All Suites", icon: "square.stack.3d.up", color: CeptraTheme.success, shortcut: "⌘⇧M") {
                    appState.run(mode: .runMultiple(suites: [], runAll: true))
                }
                if let suites = appState.workspace?.config.multipleSuites, !suites.isEmpty {
                    ForEach(suites) { suite in
                        menuRow("Multiple: \(suite.name)", icon: "play.square.stack", color: CeptraTheme.accent) {
                            appState.run(mode: .runMultiple(suites: [suite.name], runAll: false))
                        }
                    }
                }
                menuRow("Configure Multiple Run…", icon: "square.stack.3d.up.fill") {
                    appState.presentParallelRunSheet(tab: .multiple)
                }

                CeptraDropdownDivider()
                CeptraDropdownSectionHeader(title: "Runtime & Console")

                HStack(spacing: 8) {
                    Text("Runtime")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 50, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { appState.settings.jsRuntime },
                        set: { appState.setJSRuntime($0) }
                    )) {
                        ForEach(JSRuntimeKind.allCases) { rt in
                            Text(rt.shortName).tag(rt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

                HStack(spacing: 8) {
                    Text("Console")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 50, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { appState.settings.consoleExecutionMode },
                        set: { appState.setConsoleExecutionMode($0) }
                    )) {
                        Text("Built-in").tag(ConsoleExecutionMode.builtIn)
                        Text(appState.activeTerminalDisplayName).tag(ConsoleExecutionMode.systemTerminal)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

                menuRow("Open Workspace in \(appState.activeTerminalDisplayName)", icon: "arrow.up.forward.app", color: CeptraTheme.cyan, shortcut: "⌘⇧T") {
                    appState.openWorkspaceInSystemTerminal()
                }

                CeptraDropdownDivider()
                CeptraDropdownSectionHeader(title: "Replay & Run Settings")

                Toggle(isOn: Binding(
                    get: { appState.settings.modulePreferences.autoOpenReplayOnRun },
                    set: { appState.setAutoOpenReplayOnRun($0) }
                )) {
                    Text("Auto-open Replay on Run")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

                Toggle(isOn: Binding(
                    get: { appState.runOptions.debugLaunchOptions.headedBrowser },
                    set: {
                        appState.runOptions.debugLaunchOptions.headedBrowser = $0
                        appState.saveSettings()
                    }
                )) {
                    Text("Headed Browser")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

                menuRow("CodeceptJS Run Options…", icon: "slider.horizontal.3", color: CeptraTheme.accent) {
                    appState.showingRunOptionsPopover = true
                }

                CeptraDropdownDivider()
                CeptraDropdownSectionHeader(title: "CodeceptJS CLI Tools")
                menuRow("Check Environment (codeceptjs check)", icon: "stethoscope") {
                    appState.run(mode: .checkEnvironment)
                }
                menuRow("Generate Type Defs (codeceptjs def)", icon: "curlybraces") {
                    appState.run(mode: .generateDefinitions)
                }
                menuRow("List I.* Actions (codeceptjs list)", icon: "list.bullet.rectangle") {
                    appState.run(mode: .listActions)
                }
            }
            .padding(8)
        }
        .frame(width: 288)
        .frame(maxHeight: 460)
        .background(CeptraTheme.panelBG)
    }

    private func menuRow(_ title: String, icon: String, color: Color = CeptraTheme.textSecondary, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            isPresented = false
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.isRunning && title.hasPrefix("Run"))
    }
}

// MARK: - ⊞ Tools & Modules Popover (Zero Dynamic Header Spawning)

private struct ToolsControlPopover: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Tools & Modules")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        Text("Toggle any module — header stays clean")
                            .font(.system(size: 10.5))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    Spacer()
                }
                .padding(.bottom, 2)

                VStack(spacing: 4) {
                    moduleSwitchRow("Explorer Sidebar", subtitle: "Suites, Files & Pages", shortcut: "⌘B", isOn: Binding(
                        get: { appState.isSidebarVisible },
                        set: { _ in appState.toggleLeftSidebar() }
                    ))
                    moduleSwitchRow("Terminal & Logs", subtitle: "Streaming output, scripts & pause()", shortcut: "⌘J", isOn: Binding(
                        get: { appState.isConsoleVisible },
                        set: { _ in appState.toggleTerminal() }
                    ))
                    moduleSwitchRow("Replay", subtitle: "Visual, DOM, Network & Console player", shortcut: "⌘⌥T", isOn: Binding(
                        get: { appState.isRightSidebarVisible && appState.activeRightTab == .replay },
                        set: { _ in appState.toggleRightTab(.replay) }
                    ))
                    moduleSwitchRow("CodeceptUI Live", subtitle: "Embedded @codeceptjs/ui dashboard", shortcut: "⌘⌥U", isOn: Binding(
                        get: { appState.isRightSidebarVisible && appState.activeRightTab == .codeceptUI },
                        set: { _ in appState.toggleRightTab(.codeceptUI) }
                    ))
                    moduleSwitchRow("Flow Outline", subtitle: "Flat hooks & scenario pipeline", shortcut: "⌘⌥O", isOn: Binding(
                        get: { appState.isRightSidebarVisible && appState.activeRightTab == .outline },
                        set: { _ in appState.toggleRightTab(.outline) }
                    ))
                    moduleSwitchRow("Debug & Breakpoints", subtitle: "CDP inspector, locals & stepping", shortcut: "⌘⌥J", isOn: Binding(
                        get: { appState.isRightSidebarVisible && appState.activeRightTab == .debug },
                        set: { _ in appState.toggleRightTab(.debug) }
                    ))
                }

                Divider().overlay(CeptraTheme.border)

                VStack(spacing: 4) {
                    moduleSwitchRow("Bottom Module Strip", subtitle: "28pt 1-click ON/OFF module bar", shortcut: nil, isOn: Binding(
                        get: { appState.isStatusBarVisible },
                        set: { appState.setStatusBarVisible($0) }
                    ))
                    moduleSwitchRow("Auto-open Replay on Run", subtitle: "Open Replay automatically when running", shortcut: nil, isOn: Binding(
                        get: { appState.settings.modulePreferences.autoOpenReplayOnRun },
                        set: { appState.setAutoOpenReplayOnRun($0) }
                    ))
                }

                Divider().overlay(CeptraTheme.border)

                // Quick Editor & Workspace Actions
                VStack(spacing: 3) {
                    quickActionRow("Command Palette…", icon: "magnifyingglass", shortcut: "⌘K") {
                        appState.showingToolsPopover = false
                        appState.showingCommandPalette = true
                    }
                    quickActionRow("Run History & Artifacts…", icon: "chart.bar.doc.horizontal") {
                        appState.showingToolsPopover = false
                        appState.showingReportsSheet = true
                    }
                    quickActionRow("CodeceptJS Run Options…", icon: "slider.horizontal.3") {
                        appState.showingToolsPopover = false
                        appState.showingRunOptionsPopover = true
                    }
                    if appState.activeTab != nil {
                        HStack(spacing: 6) {
                            Button {
                                appState.triggerEditorFold(.collapseAll)
                            } label: {
                                Label("Fold All", systemImage: "rectangle.compress.vertical")
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            Button {
                                appState.triggerEditorFold(.expandAll)
                            } label: {
                                Label("Unfold All", systemImage: "rectangle.expand.vertical")
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 2)

                        Menu {
                            ForEach(CodeSnippetItem.builtInSnippets) { snippet in
                                Button(snippet.title) {
                                    appState.insertSnippet(snippet)
                                    appState.showingToolsPopover = false
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "curlybraces.square")
                                    .font(.system(size: 11))
                                    .foregroundStyle(CeptraTheme.textSecondary)
                                Text("Insert CodeceptJS Snippet…")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(CeptraTheme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(CeptraTheme.textMuted)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider().overlay(CeptraTheme.border)

                // Appearance Switcher
                VStack(alignment: .leading, spacing: 6) {
                    Text("APPEARANCE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(CeptraTheme.textMuted)
                    Picker("", selection: Binding(
                        get: { appState.settings.appearance },
                        set: {
                            appState.settings.appearance = $0
                            appState.saveSettings()
                        }
                    )) {
                        Text("Dark").tag(WorkspaceAppearance.dark)
                        Text("Light").tag(WorkspaceAppearance.light)
                        Text("System").tag(WorkspaceAppearance.system)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(14)
        }
        .frame(width: 320)
        .frame(maxHeight: 540)
        .background(CeptraTheme.panelBG)
    }

    private func moduleSwitchRow(_ title: String, subtitle: String, shortcut: String?, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func quickActionRow(_ title: String, icon: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(CeptraTheme.textPrimary)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Slim 28pt Bottom 1-Click Module Dock & Balanced Status Strip

private struct BottomModuleStatusStrip: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 1040

            HStack(spacing: 10) {
                // Left: 1-Click ON/OFF Module Pills
                HStack(spacing: 3) {
                    dockPill("Explorer", isOn: appState.isSidebarVisible) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.toggleLeftSidebar()
                        }
                    }
                    dockPill("Terminal", isOn: appState.isConsoleVisible) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.toggleTerminal()
                        }
                    }
                    dockPill("Replay", isOn: appState.isRightSidebarVisible && appState.activeRightTab == .replay) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.toggleRightTab(.replay)
                        }
                    }
                    dockPill("CodeceptUI", isOn: appState.isRightSidebarVisible && appState.activeRightTab == .codeceptUI) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.toggleRightTab(.codeceptUI)
                        }
                    }
                    if !isCompact {
                        dockPill("Outline", isOn: appState.isRightSidebarVisible && appState.activeRightTab == .outline) {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                                appState.toggleRightTab(.outline)
                            }
                        }
                        dockPill("Debug", isOn: appState.debugPhase.isActive || (appState.isRightSidebarVisible && appState.activeRightTab == .debug)) {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                                appState.toggleRightTab(.debug)
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                // Right: ● Playwright | Ln X, Col Y · Replay ON · v1.4
                HStack(spacing: 10) {
                    if let ws = appState.workspace {
                        CeptraGlassDropdown(arrowEdge: .top, minWidth: 240, maxWidth: 320) { _ in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(CeptraTheme.success)
                                    .frame(width: 6, height: 6)
                                Text(appState.activeHelperDisplayName)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.success)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        } content: {
                            if !ws.discoveredConfigPaths.isEmpty {
                                CeptraDropdownSectionHeader(title: "Active Config (-c)")
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
                            CeptraDropdownItem(title: "Choose Custom Config File…", systemImage: "folder", shortcut: "⌘⇧C") {
                                appState.selectCustomConfigPanel()
                            }
                            if ws.config.configFilePath != nil {
                                CeptraDropdownItem(title: "Open Active Config in Editor", systemImage: "square.and.pencil") {
                                    appState.openActiveConfigFile()
                                }
                            }
                            if ws.config.isCustomConfigOverride {
                                CeptraDropdownDivider()
                                CeptraDropdownItem(title: "Reset to Auto-Detect", systemImage: "arrow.counterclockwise", iconColor: CeptraTheme.accentWarm) {
                                    appState.setCustomConfigFile(path: nil)
                                }
                            }
                        }
                        .fixedSize()
                        .help("Active Helper: \(appState.activeHelperDisplayName) — Click to open or switch CodeceptJS config")
                    }

                    Rectangle()
                        .fill(CeptraTheme.borderStrong)
                        .frame(width: 1, height: 11)

                    Text("Ln \(appState.cursorLine), Col \(appState.cursorColumn)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(CeptraTheme.textMuted)

                    if !isCompact {
                        Text(appState.settings.modulePreferences.autoOpenReplayOnRun ? "Replay ON" : "Replay OFF")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(appState.settings.modulePreferences.autoOpenReplayOnRun ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                    }

                    Button {
                        appState.showingUpdateSheet = true
                        if case .idle = appState.updateState {
                            Task { await appState.checkForUpdates(userInitiated: true) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if appState.updateState.hasActionableUpdate {
                                Circle()
                                    .fill(CeptraTheme.accentWarm)
                                    .frame(width: 6, height: 6)
                            }
                            Text(appState.updateState.hasActionableUpdate ? "Update" : "v\(AppMetadata.currentVersionString)")
                                .font(.system(size: 10.5, weight: appState.updateState.hasActionableUpdate ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(appState.updateState.hasActionableUpdate ? CeptraTheme.accentWarm : CeptraTheme.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Ceptra v\(AppMetadata.currentVersionString) — Check for Updates")
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 28)
        .overlay(alignment: .top) {
            Rectangle().fill(CeptraTheme.border).frame(height: 1)
        }
    }

    private func dockPill(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isOn ? CeptraTheme.success : CeptraTheme.textMuted.opacity(0.6))
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 10.5, weight: isOn ? .medium : .regular))
                    .foregroundStyle(isOn ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? CeptraTheme.hoverBG : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func displayPath(_ path: String, relativeTo root: URL) -> String {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let stdRoot = root.standardizedFileURL.path
        let prefix = stdRoot.hasSuffix("/") ? stdRoot : stdRoot + "/"
        return stdPath.hasPrefix(prefix) ? String(stdPath.dropFirst(prefix.count)) : stdPath
    }
}

// MARK: - Clean In-Window Editor Tab Bar (Drag-to-Reorder · Zero Duplicate Toolbar Clutter)

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

    @State private var hoveredTabPath: String?
    @State private var hoveredClosePath: String?
    @State private var tabWidths: [String: CGFloat] = [:]

    @State private var draggingTabPath: String?
    @State private var dragOriginIndex: Int?
    @State private var dragTargetIndex: Int?
    @State private var dragTranslationX: CGFloat = 0

    @State private var settlingTabPath: String?
    @State private var settlingOffsetX: CGFloat = 0
    @State private var settlingToken: UUID?

    private static let railCoordinateSpace = "EditorTabRail"
    private static let tabSpacing: CGFloat = 0
    private static let railHorizontalPadding: CGFloat = 0
    private static let dragActivationDistance: CGFloat = 5
    private static let fallbackTabWidth: CGFloat = 132

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
            if hasNavigationHistory {
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
                .padding(.horizontal, 6)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(CeptraTheme.border).frame(width: 1)
                }
            }

            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .leading) {
                        if let slot = dropSlotIndicatorRect {
                            Rectangle()
                                .fill(CeptraTheme.accent.opacity(0.08))
                                .frame(width: slot.width, height: 36)
                                .offset(x: slot.minX)
                                .allowsHitTesting(false)
                                .zIndex(0)
                        }

                        HStack(spacing: Self.tabSpacing) {
                            ForEach(appState.openTabs) { tab in
                                let tabIndex = currentIndexByPath[tab.filePath] ?? 0
                                tabCell(for: tab, index: tabIndex)
                                    .id(tab.filePath)
                            }
                        }
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
                        Button("Save") {
                            appState.saveActiveFile()
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.accentWarm)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(CeptraTheme.accentWarm.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .buttonStyle(.plain)
                        .help("Save \(tab.name) (⌘S)")
                    }

                    Text(tab.relativePath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.trailing, 12)
            }
        }
        .frame(height: 36)
        .background(CeptraTheme.sidebarBG)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CeptraTheme.border).frame(height: 1)
        }
        .modifier(TabDragPointerModifier(isDragging: draggingTabPath != nil))
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
    private func tabCell(for tab: OpenDocumentTab, index: Int) -> some View {
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
                  !isDragged else { return 0 }
            let draggedWidth = Double(tabWidths[draggingPath] ?? Self.fallbackTabWidth)
            return CGFloat(TabReorderEngine.displacement(
                forOriginalIndex: index,
                originIndex: originIndex,
                targetIndex: targetIndex,
                draggedWidth: draggedWidth,
                spacing: Double(Self.tabSpacing)
            ))
        }()

        let horizontalOffset: CGFloat = isDragged ? dragTranslationX : (isSettling ? settlingOffsetX : siblingDisplacement)
        let tabZIndex: Double = isDragged ? 100 : (isSettling ? 50 : (isActive ? 10 : 1))
        let tagInfo = shortTag(for: tab)

        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(tagInfo.label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tagInfo.color)
                Text(tab.name)
                    .font(.system(size: 11.5, weight: (isActive || isDragged) ? .medium : .regular))
                    .foregroundStyle(
                        (isActive || isDragged)
                            ? CeptraTheme.textPrimary
                            : (isHovered ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                    )
                    .lineLimit(1)
                if tab.isDirty {
                    Circle()
                        .fill(CeptraTheme.accentWarm)
                        .frame(width: 5.5, height: 5.5)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 2)
            .frame(height: 36)
            .contentShape(Rectangle())
            .help(appState.openTabs.count > 1 ? "\(tab.relativePath) — Drag to reorder" : tab.relativePath)
            .gesture(tabDragGesture(for: tab, index: index))

            Button {
                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                    appState.closeTab(filePath: tab.filePath)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isCloseHovered ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                    .opacity(isActive || isHovered || isCloseHovered ? 1.0 : 0.45)
                    .frame(width: 18, height: 18)
                    .background(isCloseHovered ? CeptraTheme.hoverBG : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help("Close Tab (⌘W)")
            .onHover { hovering in
                hoveredClosePath = hovering ? tab.filePath : (hoveredClosePath == tab.filePath ? nil : hoveredClosePath)
            }
        }
        .background(isActive ? CeptraTheme.canvasBG : (isHovered ? CeptraTheme.hoverBG : Color.clear))
        .overlay(alignment: .trailing) {
            Rectangle().fill(CeptraTheme.border).frame(width: 1)
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TabWidthPreferenceKey.self, value: [tab.filePath: proxy.size.width])
            }
        )
        .offset(x: horizontalOffset)
        .zIndex(tabZIndex)
        .animation(
            isAnyDragging && !isDragged ? CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion) : nil,
            value: siblingDisplacement
        )
        .onHover { hovering in
            guard draggingTabPath == nil else { return }
            hoveredTabPath = hovering ? tab.filePath : (hoveredTabPath == tab.filePath ? nil : hoveredTabPath)
        }
    }

    private func shortTag(for tab: OpenDocumentTab) -> (label: String, color: Color) {
        switch tab.category {
        case .pageObject: return ("PO", CeptraTheme.violet)
        case .gherkinFeature: return ("BDD", CeptraTheme.violet)
        case .config: return ("CFG", CeptraTheme.accentWarm)
        case .helper: return ("HLP", CeptraTheme.cyan)
        default:
            let ext = URL(fileURLWithPath: tab.filePath).pathExtension.uppercased()
            return (ext.isEmpty ? "TXT" : String(ext.prefix(3)), CeptraTheme.accent)
        }
    }

    private func tabDragGesture(for tab: OpenDocumentTab, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.railCoordinateSpace))
            .onChanged { value in
                let dx = value.location.x - value.startLocation.x
                if draggingTabPath != tab.filePath {
                    guard draggingTabPath == nil,
                          appState.openTabs.count > 1,
                          abs(dx) >= Self.dragActivationDistance else { return }
                    settlingToken = nil
                    settlingTabPath = nil
                    settlingOffsetX = 0
                    hoveredTabPath = nil
                    hoveredClosePath = nil
                    draggingTabPath = tab.filePath
                    dragOriginIndex = index
                    dragTargetIndex = index
                }

                guard let originIndex = dragOriginIndex, let currentTarget = dragTargetIndex else { return }
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
                Toggle("Capture Replay Trace (DOM, Network, Shots)", isOn: $appState.runOptions.timeTravelTrace)
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
        .background(CeptraTheme.panelBG)
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
            tintOpacity: 0.78,
            accentBorder: isError ? CeptraTheme.failure : CeptraTheme.success,
            elevatedShadow: true
        )
    }
}
