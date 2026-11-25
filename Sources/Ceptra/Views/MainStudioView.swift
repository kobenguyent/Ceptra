import AppKit
import CeptraCore
import SwiftUI

struct MainStudioView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sidebarWidth: CGFloat = 264
    @State private var sidebarDragStartWidth: CGFloat = 264
    @State private var isResizingSidebar = false

    @State private var rightInspectorWidth: CGFloat = 348
    @State private var inspectorDragStartWidth: CGFloat = 348
    @State private var isResizingInspector = false

    @State private var mobileSidebarWidth: CGFloat = 396

    @State private var consoleBodyHeight: CGFloat = 190
    @State private var consoleDragStartHeight: CGFloat = 190
    @State private var isResizingConsole = false

    @State private var mobileInspectorBodyHeight: CGFloat = 330
    @State private var mobileInspectorDragStartHeight: CGFloat = 330
    @State private var isResizingMobileInspector = false
    @State private var isMobileInspectorExpanded = true

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
        .sheet(isPresented: $appState.showingCodeSnapshotSheet) {
            CodeSnapshotSheetView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingAIProviderSettingsSheet) {
            AIProviderSettingsSheetView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showingMobileDeviceWizard) {
            MobileDeviceSetupWizardSheetView()
                .environmentObject(appState)
        }
        .sheet(item: $appState.pendingAIDiffPreview) { preview in
            AIDiffPreviewSheetView(preview: preview)
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
        .onChange(of: appState.isMobileStudioVisible) { _, isVisible in
            guard isVisible else { return }
            isMobileInspectorExpanded = true
            ensureSpaciousMobileStudioWindowSize()
        }
    }

    private func ensureSpaciousMobileStudioWindowSize() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            return
        }
        // Skip resizing if the window is currently in native macOS Full Screen
        if window.styleMask.contains(.fullScreen) {
            return
        }
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetWidth = min(1440.0, visibleFrame.width - 24.0)
        let targetHeight = min(880.0, visibleFrame.height - 24.0)

        var frame = window.frame
        let newWidth = max(frame.width, targetWidth)
        let newHeight = max(frame.height, targetHeight)
        guard newWidth > frame.width + 1 || newHeight > frame.height + 1 else { return }

        // Keep top-left anchored smoothly, then clamp strictly inside visibleFrame
        let deltaH = newHeight - frame.height
        frame.origin.y -= deltaH
        frame.size.width = newWidth
        frame.size.height = newHeight

        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
        }
        if frame.minX < visibleFrame.minX {
            frame.origin.x = visibleFrame.minX
        }
        if frame.minY < visibleFrame.minY {
            frame.origin.y = visibleFrame.minY
        }
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
        }

        window.setFrame(frame, display: true, animate: !reduceMotion)
    }

    // MARK: - Three Soft-Edged Vertical Windows

    private var threeWindowStage: some View {
        GeometryReader { rootGeo in
            let outerPadding: CGFloat = 8
            let gapW: CGFloat = 8
            let usableW = max(0, rootGeo.size.width - outerPadding * 2)

            let showMobileLeft = appState.isMobileStudioVisible && appState.mobilePhoneDockSide == .left
            let showMobileRight = appState.isMobileStudioVisible && appState.mobilePhoneDockSide == .right
            let leftColumnVisible = showMobileLeft || appState.isSidebarVisible
            let rightColumnVisible = showMobileRight || appState.isRightSidebarVisible

            let minLeftW: CGFloat = showMobileLeft ? 320 : 228
            let maxLeftW: CGFloat = max(minLeftW, min(showMobileLeft ? 520 : 380, usableW * (showMobileLeft ? 0.44 : 0.32)))
            let desiredLeftW = showMobileLeft ? mobileSidebarWidth : sidebarWidth
            let effectiveLeftW = min(max(desiredLeftW, minLeftW), maxLeftW)
            let leftCursor: CeptraSplitResizeHandle.CursorDirection =
                effectiveLeftW <= minLeftW + 0.5
                    ? .onlyTrailingOrDown
                    : (effectiveLeftW >= maxLeftW - 0.5 ? .onlyLeadingOrUp : .both)

            let minRightW: CGFloat = showMobileRight ? 320 : 296
            let leftReserve: CGFloat = leftColumnVisible ? (effectiveLeftW + gapW) : 0
            let centerMinReserve: CGFloat = 300 + gapW
            let availableForRight = max(minRightW, usableW - leftReserve - centerMinReserve)
            let maxRightW: CGFloat = max(minRightW, min(760, min(usableW * 0.56, availableForRight)))
            let desiredRightW = showMobileRight ? mobileSidebarWidth : rightInspectorWidth
            let effectiveRightW = min(max(desiredRightW, minRightW), maxRightW)
            let rightCursor: CeptraSplitResizeHandle.CursorDirection =
                effectiveRightW <= minRightW + 0.5
                    ? .onlyLeadingOrUp
                    : (effectiveRightW >= maxRightW - 0.5 ? .onlyTrailingOrDown : .both)

            HStack(spacing: 0) {
                // WINDOW 1 (LEFT): Dedicated Mobile Phone Sidebar (when docked Left) OR Smart Explorer
                Group {
                    if showMobileLeft {
                        MobilePhoneSidebarView()
                            .ceptraPaneWindow(subtle: true)
                    } else {
                        SidebarExplorerView()
                            .ceptraPaneWindow(subtle: true)
                    }
                }
                .frame(minWidth: effectiveLeftW, idealWidth: effectiveLeftW, maxWidth: effectiveLeftW)
                .clipped()
                .opacity(leftColumnVisible ? 1 : 0)
                .offset(x: leftColumnVisible || reduceMotion ? 0 : -10)
                .frame(
                    minWidth: leftColumnVisible ? effectiveLeftW : 0,
                    idealWidth: leftColumnVisible ? effectiveLeftW : 0,
                    maxWidth: leftColumnVisible ? effectiveLeftW : 0,
                    alignment: .trailing
                )
                .clipped()
                .allowsHitTesting(leftColumnVisible)
                .accessibilityHidden(!leftColumnVisible)

                if leftColumnVisible {
                    CeptraSplitResizeHandle(
                        axis: .horizontal,
                        cursorDirection: leftCursor,
                        isSoftGap: true,
                        onDragStart: {
                            isResizingSidebar = true
                            sidebarDragStartWidth = effectiveLeftW
                        },
                        onDragChanged: { delta in
                            let next = min(max(sidebarDragStartWidth + delta, minLeftW), maxLeftW)
                            if showMobileLeft {
                                mobileSidebarWidth = next
                            } else {
                                sidebarWidth = next
                            }
                        },
                        onDragEnd: {
                            isResizingSidebar = false
                        },
                        onDoubleClick: {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                                if showMobileLeft {
                                    mobileSidebarWidth = 396
                                } else {
                                    sidebarWidth = 264
                                }
                            }
                        }
                    )
                    .frame(width: gapW)
                }

                // WINDOW 2 (CENTER): Soft-Edged In-Window Tabs + Code Editor + Terminal Drawer
                centerSoftWindow
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                if rightColumnVisible {
                    CeptraSplitResizeHandle(
                        axis: .horizontal,
                        cursorDirection: rightCursor,
                        isSoftGap: true,
                        onDragStart: {
                            isResizingInspector = true
                            inspectorDragStartWidth = effectiveRightW
                        },
                        onDragChanged: { delta in
                            let next = min(max(inspectorDragStartWidth - delta, minRightW), maxRightW)
                            if showMobileRight {
                                mobileSidebarWidth = next
                            } else {
                                rightInspectorWidth = next
                            }
                        },
                        onDragEnd: {
                            isResizingInspector = false
                        },
                        onDoubleClick: {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                                if showMobileRight {
                                    mobileSidebarWidth = 396
                                } else {
                                    rightInspectorWidth = 348
                                }
                            }
                        }
                    )
                    .frame(width: gapW)
                }

                // WINDOW 3 (RIGHT): Dedicated Mobile Phone Sidebar (when docked Right) OR Single-Slot Inspector
                Group {
                    if showMobileRight {
                        MobilePhoneSidebarView()
                            .ceptraPaneWindow(subtle: true)
                    } else {
                        RightInspectorWindowView()
                    }
                }
                .frame(minWidth: effectiveRightW, idealWidth: effectiveRightW, maxWidth: effectiveRightW)
                .clipped()
                .opacity(rightColumnVisible ? 1 : 0)
                .offset(x: rightColumnVisible || reduceMotion ? 0 : 10)
                .frame(
                    minWidth: rightColumnVisible ? effectiveRightW : 0,
                    idealWidth: rightColumnVisible ? effectiveRightW : 0,
                    maxWidth: rightColumnVisible ? effectiveRightW : 0,
                    alignment: .leading
                )
                .clipped()
                .allowsHitTesting(rightColumnVisible)
                .accessibilityHidden(!rightColumnVisible)
            }
            .padding(.horizontal, outerPadding)
            .padding(.top, 2)
            .padding(.bottom, appState.isStatusBarVisible ? 6 : 8)
            .frame(width: rootGeo.size.width, height: rootGeo.size.height, alignment: .leading)
            .animation(
                isResizingSidebar ? nil : CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion),
                value: leftColumnVisible
            )
            .animation(
                isResizingInspector ? nil : CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion),
                value: rightColumnVisible
            )
            .animation(
                CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion),
                value: appState.mobilePhoneDockSide
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

            let minMobileInspectorBody: CGFloat = 156
            let consoleReserve: CGFloat = appState.isConsoleVisible ? (effectiveConsoleBody + ConsoleDrawerView.headerHeight + handleH) : 0
            let maxMobileInspectorBody = max(
                minMobileInspectorBody,
                min(440, colGeo.size.height - consoleReserve - 220)
            )
            let effectiveMobileInspectorBody = min(max(mobileInspectorBodyHeight, minMobileInspectorBody), maxMobileInspectorBody)
            let mobileInspectorCursor: CeptraSplitResizeHandle.CursorDirection =
                effectiveMobileInspectorBody <= minMobileInspectorBody + 0.5
                    ? .onlyTrailingOrDown
                    : (effectiveMobileInspectorBody >= maxMobileInspectorBody - 0.5 ? .onlyLeadingOrUp : .both)

            VStack(spacing: 0) {
                if appState.isAPIStudioVisible {
                    APIStudioView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EditorTabBar()

                    if appState.isMobileStudioVisible {
                        MobileElementInspectorPanel(
                            isExpanded: $isMobileInspectorExpanded,
                            bodyHeight: effectiveMobileInspectorBody
                        )
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))

                        if isMobileInspectorExpanded {
                            CeptraSplitResizeHandle(
                                axis: .vertical,
                                cursorDirection: mobileInspectorCursor,
                                onDragStart: {
                                    isResizingMobileInspector = true
                                    mobileInspectorDragStartHeight = effectiveMobileInspectorBody
                                },
                                onDragChanged: { delta in
                                    mobileInspectorBodyHeight = min(max(mobileInspectorDragStartHeight + delta, minMobileInspectorBody), maxMobileInspectorBody)
                                },
                                onDragEnd: {
                                    isResizingMobileInspector = false
                                },
                                onDoubleClick: {
                                    withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                                        mobileInspectorBodyHeight = 330
                                    }
                                }
                            )
                        }
                    }

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
                        ZStack(alignment: .bottomTrailing) {
                            editorSurface(for: activeTab)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if let hudText = appState.zoomHUDText {
                                HStack(spacing: 6) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(CeptraTheme.accent)
                                    Text(hudText)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .monospacedDigit()
                                        .contentTransition(.numericText())
                                        .foregroundStyle(CeptraTheme.textPrimary)
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(CeptraTheme.panelBG.opacity(0.94), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(CeptraTheme.borderStrong, lineWidth: 1)
                                )
                                .shadow(color: Color.black.opacity(0.24), radius: 10, y: 4)
                                .padding(14)
                                .allowsHitTesting(false)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing)))
                            }
                        }
                        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: appState.zoomHUDText)
                    } else {
                        emptyEditorPlaceholder
                    }
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
            },
            onSelectionChanged: { selectedText, selectedRange, lineRange in
                appState.updateEditorSelection(text: selectedText, range: selectedRange, lineRange: lineRange)
            },
            onAIQuickAction: { action in
                appState.triggerAIQuickAction(action)
            },
            editorMutationTrigger: appState.editorMutationTrigger,
            pendingEditorMutation: appState.pendingEditorMutation,
            onZoomDelta: { delta in
                appState.applyZoomDelta(Double(delta))
            },
            onResetZoom: {
                appState.resetZoom()
            },
            onQuickCopyCodeSnapshot: {
                appState.quickCopyCodeSnapshot()
            },
            onOpenCodeSnapshotStudio: {
                appState.openCodeSnapshotStudio()
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
                        .font(.system(size: 13.5, weight: .semibold))
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
                        title: "Create Sample Playwright Test Workspace…",
                        systemImage: "theatermasks",
                        iconColor: CeptraTheme.success
                    ) {
                        appState.createSamplePlaywrightWorkspacePanel()
                    }
                    CeptraDropdownItem(
                        title: "Create Sample Playwright Python Workspace…",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        iconColor: CeptraTheme.cyan
                    ) {
                        appState.createSamplePlaywrightPythonWorkspacePanel()
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
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textMuted)

                    Button {
                        appState.showingCommandPalette = true
                    } label: {
                        Text(activeTab.name)
                            .font(.system(size: 13, weight: .regular))
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

                    // 2. AI Assistant Toggle
                    let isAIOpen = appState.isRightSidebarVisible && appState.activeRightTab == .ai
                    CeptraTitlebarIconButton(
                        systemImage: "sparkles",
                        isActive: isAIOpen,
                        indicatorColor: CeptraTheme.accent,
                        activeIconColor: CeptraTheme.accent,
                        showActivityDot: appState.isAIStreaming && !isAIOpen,
                        helpText: "Toggle AI Assistant (⌘⌥A)",
                        accessibilityLabelText: "Toggle AI Assistant"
                    ) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.toggleRightTab(.ai)
                        }
                    }

                    // 3. Right Sidebar Toggle
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

                    // 4. Tools & Modules Popover
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
        .frame(height: 42)
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
                HStack(spacing: 5.5) {
                    if isRunning {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10.5, weight: .bold))
                    }
                    Text(isRunning ? "Stop" : "Run")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(fg)
                .padding(.leading, 11)
                .padding(.trailing, 9)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRunning ? "Stop Running Tests (⌘.)" : (appState.isActiveTabExecutableTestFile ? "Run Active Test File (⌘⇧R)" : "Run All Tests (⌘R)"))

            Rectangle()
                .fill(Color.black.opacity(0.18))
                .frame(width: 1, height: 16)

            Button {
                showingRunMenu.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(fg)
                    .frame(width: 24, height: 28)
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
                menuRow(
                    appState.isPlaywrightPythonWorkspace
                        ? "Collect Tests (pytest --co)"
                        : (appState.isPlaywrightWorkspace ? "List Tests (playwright test --list)" : "Dry Run (Validate & List)"),
                    icon: "checklist",
                    shortcut: "⌘⇧D"
                ) {
                    appState.run(mode: .dryRun(relativePath: nil))
                }

                CeptraDropdownDivider()
                CeptraDropdownSectionHeader(
                    title: appState.isPlaywrightPythonWorkspace
                        ? "Debug, Workers & Browsers"
                        : (appState.isPlaywrightWorkspace ? "Debug, Workers & Projects" : "Debug & Parallel")
                )
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
                    appState.isPlaywrightPythonWorkspace
                        ? "Run Workers (pytest -n \(appState.runOptions.workerCount))"
                        : (appState.isPlaywrightWorkspace
                            ? "Run Workers (--workers=\(appState.runOptions.workerCount))"
                            : "Run Workers (\(appState.runOptions.workerCount)× \(appState.runOptions.workerStrategy.rawValue))"),
                    icon: "cpu",
                    color: CeptraTheme.cyan,
                    shortcut: "⌘⇧W"
                ) {
                    appState.runWorkersWithCurrentOptions()
                }
                menuRow("Configure Workers…", icon: "slider.horizontal.3") {
                    appState.presentParallelRunSheet(tab: .workers)
                }
                menuRow(
                    appState.isPlaywrightPythonWorkspace
                        ? "Run All Browsers"
                        : (appState.isPlaywrightWorkspace ? "Run All Projects" : "Run Multiple — All Suites"),
                    icon: "square.stack.3d.up",
                    color: CeptraTheme.success,
                    shortcut: "⌘⇧M"
                ) {
                    appState.run(mode: .runMultiple(suites: [], runAll: true))
                }
                if let suites = appState.workspace?.config.multipleSuites, !suites.isEmpty {
                    ForEach(suites) { suite in
                        menuRow(
                            appState.isPlaywrightPythonWorkspace
                                ? "Browser: \(suite.name)"
                                : (appState.isPlaywrightWorkspace ? "Project: \(suite.name)" : "Multiple: \(suite.name)"),
                            icon: "play.square.stack",
                            color: CeptraTheme.accent
                        ) {
                            appState.run(mode: .runMultiple(suites: [suite.name], runAll: false))
                        }
                    }
                }
                menuRow(
                    appState.isPlaywrightPythonWorkspace
                        ? "Configure Browsers Run…"
                        : (appState.isPlaywrightWorkspace ? "Configure Projects Run…" : "Configure Multiple Run…"),
                    icon: "square.stack.3d.up.fill"
                ) {
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
                    get: {
                        appState.isPlaywrightWorkspace
                            ? appState.runOptions.playwrightHeaded
                            : appState.runOptions.debugLaunchOptions.headedBrowser
                    },
                    set: {
                        if appState.isPlaywrightWorkspace {
                            appState.runOptions.playwrightHeaded = $0
                            appState.runOptions.debugLaunchOptions.headedBrowser = $0
                        } else {
                            appState.runOptions.debugLaunchOptions.headedBrowser = $0
                        }
                        appState.saveSettings()
                    }
                )) {
                    Text(appState.isPlaywrightWorkspace ? "Headed Browser (--headed)" : "Headed Browser")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

                menuRow(
                    appState.isPlaywrightWorkspace ? "Playwright Run Options…" : "CodeceptJS Run Options…",
                    icon: "slider.horizontal.3",
                    color: CeptraTheme.accent
                ) {
                    appState.showingRunOptionsPopover = true
                }

                CeptraDropdownDivider()
                if appState.isPlaywrightPythonWorkspace {
                    CeptraDropdownSectionHeader(title: "Playwright Python CLI Tools")
                    menuRow("Record with Codegen (python-pytest)", icon: "record.circle", color: CeptraTheme.failure) {
                        appState.launchPlaywrightCodegen()
                    }
                    menuRow("Open Playwright Trace Viewer", icon: "doc.richtext", color: CeptraTheme.accent) {
                        appState.openPlaywrightHTMLReport()
                    }
                    menuRow("Check Pytest & Playwright Version", icon: "stethoscope") {
                        appState.run(mode: .checkEnvironment)
                    }
                    menuRow("Collect Tests (pytest --co)", icon: "list.bullet.rectangle") {
                        appState.run(mode: .listActions)
                    }
                } else if appState.isPlaywrightWorkspace {
                    CeptraDropdownSectionHeader(title: "Playwright CLI Tools")
                    menuRow("Record with Codegen (playwright codegen)", icon: "record.circle", color: CeptraTheme.failure) {
                        appState.launchPlaywrightCodegen()
                    }
                    menuRow("Open Playwright HTML Report", icon: "doc.richtext", color: CeptraTheme.accent) {
                        appState.openPlaywrightHTMLReport()
                    }
                    menuRow("Check Playwright Version", icon: "stethoscope") {
                        appState.run(mode: .checkEnvironment)
                    }
                    menuRow("List Discovered Tests (--list)", icon: "list.bullet.rectangle") {
                        appState.run(mode: .listActions)
                    }
                } else {
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
                    moduleSwitchRow(
                        appState.isPlaywrightWorkspace ? "Playwright UI Live" : "CodeceptUI Live",
                        subtitle: appState.isPlaywrightWorkspace
                            ? "Embedded playwright test --ui runner"
                            : "Embedded @codeceptjs/ui dashboard",
                        shortcut: "⌘⌥U",
                        isOn: Binding(
                            get: { appState.isRightSidebarVisible && appState.activeRightTab == .codeceptUI },
                            set: { _ in appState.toggleRightTab(.codeceptUI) }
                        )
                    )
                    moduleSwitchRow("Flow Outline", subtitle: "Flat hooks & scenario pipeline", shortcut: "⌘⌥O", isOn: Binding(
                        get: { appState.isRightSidebarVisible && appState.activeRightTab == .outline },
                        set: { _ in appState.toggleRightTab(.outline) }
                    ))
                    moduleSwitchRow("Debug & Breakpoints", subtitle: "CDP inspector, locals & stepping", shortcut: "⌘⌥J", isOn: Binding(
                        get: { appState.isRightSidebarVisible && appState.activeRightTab == .debug },
                        set: { _ in appState.toggleRightTab(.debug) }
                    ))
                    moduleSwitchRow("AI Assistant", subtitle: "Ollama, Claude, OpenAI, Gemini & CLI", shortcut: "⌘⌥A", isOn: Binding(
                        get: { appState.isRightSidebarVisible && appState.activeRightTab == .ai },
                        set: { _ in appState.toggleRightTab(.ai) }
                    ))
                    moduleSwitchRow("Mobile Phone Studio", subtitle: "Real-device mirror, inspector & recorder", shortcut: "⌘⌥M", isOn: Binding(
                        get: { appState.isMobileStudioVisible },
                        set: { _ in appState.toggleMobileStudio() }
                    ))
                    moduleSwitchRow("API Client Studio", subtitle: "Postman, Insomnia, OpenAPI, HAR & cURL", shortcut: "⌘⌥I", isOn: Binding(
                        get: { appState.isAPIStudioVisible },
                        set: { _ in appState.toggleAPIStudio() }
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
                    quickActionRow("Import API Collection / Environment…", icon: "network") {
                        appState.showingToolsPopover = false
                        appState.presentImportAPIFilePanel()
                    }
                    quickActionRow("Connect Mobile Device…", icon: "iphone.and.arrow.forward") {
                        appState.showingToolsPopover = false
                        appState.openMobileDeviceWizard()
                    }
                    quickActionRow("Command Palette…", icon: "magnifyingglass", shortcut: "⌘K") {
                        appState.showingToolsPopover = false
                        appState.showingCommandPalette = true
                    }
                    quickActionRow("Run History & Artifacts…", icon: "chart.bar.doc.horizontal") {
                        appState.showingToolsPopover = false
                        appState.showingReportsSheet = true
                    }
                    quickActionRow(
                        appState.isPlaywrightWorkspace ? "Playwright Run Options…" : "CodeceptJS Run Options…",
                        icon: "slider.horizontal.3"
                    ) {
                        appState.showingToolsPopover = false
                        appState.showingRunOptionsPopover = true
                    }
                    if appState.activeTab != nil {
                        quickActionRow("Screenshot Code Block…", icon: "camera.viewfinder", shortcut: "⌘⌥P") {
                            appState.showingToolsPopover = false
                            appState.openCodeSnapshotStudio()
                        }
                        quickActionRow("Quick Copy Code Screenshot", icon: "sparkles.rectangle.stack", shortcut: "⌘⌥⇧P") {
                            appState.showingToolsPopover = false
                            appState.quickCopyCodeSnapshot()
                        }

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
                            ForEach(CodeSnippetItem.snippets(for: appState.activeFramework)) { snippet in
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
                                Text(appState.isPlaywrightWorkspace ? "Insert Playwright Snippet…" : "Insert CodeceptJS Snippet…")
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

                // Zoom Control (⌘− · 100% · ⌘+)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("ZOOM")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(CeptraTheme.textMuted)
                        Spacer()
                        Text("⌘−  ⌘0  ⌘+")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }

                    HStack(spacing: 4) {
                        Button {
                            appState.zoomOut()
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(appState.canZoomOut ? CeptraTheme.textPrimary : CeptraTheme.textMuted.opacity(0.45))
                                .frame(width: 34, height: 24)
                                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!appState.canZoomOut)
                        .help("Zoom Out (⌘−)")

                        Button {
                            appState.resetZoom()
                        } label: {
                            Text("\(appState.editorZoomPercentage)%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(appState.isDefaultZoom ? CeptraTheme.textSecondary : CeptraTheme.accent)
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Reset Zoom to 100% (⌘0)")

                        Button {
                            appState.zoomIn()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(appState.canZoomIn ? CeptraTheme.textPrimary : CeptraTheme.textMuted.opacity(0.45))
                                .frame(width: 34, height: 24)
                                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!appState.canZoomIn)
                        .help("Zoom In (⌘+)")
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
            let isCompact = geo.size.width < 1100

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
                    dockPill(appState.activeFramework.uiToolDisplayName, isOn: appState.isRightSidebarVisible && appState.activeRightTab == .codeceptUI) {
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
                    dockPill("AI", isOn: appState.isAIStreaming || (appState.isRightSidebarVisible && appState.activeRightTab == .ai)) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.toggleRightTab(.ai)
                        }
                    }
                    dockPill("Mobile", isOn: appState.isMobileStudioVisible) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.toggleMobileStudio()
                        }
                    }
                    dockPill("API", isOn: appState.isAPIStudioVisible) {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                            appState.toggleAPIStudio()
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
                                    .frame(width: 6.5, height: 6.5)
                                Text(appState.activeHelperDisplayName)
                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
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
                                    let cfgSummary = ws.discoveredConfigs.first(where: { $0.configFilePath == path })
                                    let helperSubtitle = cfgSummary.flatMap { cfg -> String? in
                                        let prefix = cfg.framework.shortName
                                        let names = cfg.framework.isPlaywrightFamily
                                            ? cfg.playwrightProjects
                                            : cfg.helpers.map(\.name)
                                        return names.isEmpty ? prefix : "\(prefix) · \(names.joined(separator: ", "))"
                                    }
                                    CeptraDropdownItem(
                                        title: label,
                                        subtitle: helperSubtitle,
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
                        .help("Active Config: \(ws.config.displayConfigPath(relativeTo: ws.rootURL) ?? "None") (\(appState.activeHelperDisplayName)) — Click to open or switch CodeceptJS config")
                    }

                    Rectangle()
                        .fill(CeptraTheme.borderStrong)
                        .frame(width: 1, height: 12)

                    Text("Ln \(appState.cursorLine), Col \(appState.cursorColumn)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(CeptraTheme.textSecondary)

                    if !appState.isDefaultZoom {
                        Button {
                            appState.resetZoom()
                        } label: {
                            Text("\(appState.editorZoomPercentage)%")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(CeptraTheme.accent)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 2)
                                .background(CeptraTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Zoom \(appState.editorZoomPercentage)% — Click to reset to 100% (⌘0)")
                        .transition(.opacity)
                    }

                    if !isCompact {
                        Text(appState.settings.modulePreferences.autoOpenReplayOnRun ? "Replay ON" : "Replay OFF")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(appState.settings.modulePreferences.autoOpenReplayOnRun ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                    }

                    Button {
                        appState.showingUpdateSheet = true
                        if case .idle = appState.updateState {
                            Task { await appState.checkForUpdates(userInitiated: true) }
                        }
                    } label: {
                        HStack(spacing: 4.5) {
                            if appState.updateState.hasActionableUpdate {
                                Circle()
                                    .fill(CeptraTheme.accentWarm)
                                    .frame(width: 6.5, height: 6.5)
                            }
                            Text(appState.updateState.hasActionableUpdate ? "Update" : "v\(AppMetadata.currentVersionString)")
                                .font(.system(size: 11.5, weight: appState.updateState.hasActionableUpdate ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(appState.updateState.hasActionableUpdate ? CeptraTheme.accentWarm : CeptraTheme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Ceptra v\(AppMetadata.currentVersionString) — Check for Updates")
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 30)
        .overlay(alignment: .top) {
            Rectangle().fill(CeptraTheme.border).frame(height: 1)
        }
    }

    private func dockPill(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5.5) {
                Circle()
                    .fill(isOn ? CeptraTheme.success : CeptraTheme.textMuted.opacity(0.65))
                    .frame(width: 6.5, height: 6.5)
                Text(title)
                    .font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                    .foregroundStyle(isOn ? CeptraTheme.textPrimary : CeptraTheme.textSecondary.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(isOn ? CeptraTheme.hoverBG : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
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
        let parentHints = TabReorderEngine.disambiguatingParentHints(
            names: appState.openTabs.map(\.name),
            relativePaths: appState.openTabs.map(\.relativePath)
        )

        HStack(spacing: 0) {
            if hasNavigationHistory {
                HStack(spacing: 2) {
                    Button {
                        appState.navigateBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(appState.canNavigateBack ? CeptraTheme.textSecondary : CeptraTheme.textMuted.opacity(0.4))
                            .frame(width: 24, height: 26)
                    }
                    .buttonStyle(.plain)
                    .disabled(!appState.canNavigateBack)
                    .help("Navigate Back (⌃-)")

                    Button {
                        appState.navigateForward()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(appState.canNavigateForward ? CeptraTheme.textSecondary : CeptraTheme.textMuted.opacity(0.4))
                            .frame(width: 24, height: 26)
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
                                .frame(width: slot.width, height: 38)
                                .offset(x: slot.minX)
                                .allowsHitTesting(false)
                                .zIndex(0)
                        }

                        HStack(spacing: Self.tabSpacing) {
                            ForEach(appState.openTabs) { tab in
                                let tabIndex = currentIndexByPath[tab.filePath] ?? 0
                                let hint = parentHints.indices.contains(tabIndex) ? parentHints[tabIndex] : nil
                                tabCell(for: tab, index: tabIndex, parentHint: hint)
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
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .contextMenu {
                        tabBarEmptyAreaContextMenu()
                    }
            )

            Spacer(minLength: 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .contextMenu {
                    tabBarEmptyAreaContextMenu()
                }

            if let tab = appState.activeTab {
                HStack(spacing: 8) {
                    if tab.isDirty {
                        Button("Save") {
                            appState.saveActiveFile()
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.accentWarm)
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 3.5)
                        .background(CeptraTheme.accentWarm.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .buttonStyle(.plain)
                        .help("Save \(tab.name) (⌘S)")
                    }

                    Text(tab.relativePath)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)

                    if appState.openTabs.count > 1 {
                        openTabsOverflowMenu(parentHints: parentHints)
                    }

                    Button {
                        if NSEvent.modifierFlags.contains(.option) {
                            appState.quickCopyCodeSnapshot()
                        } else {
                            appState.openCodeSnapshotStudio()
                        }
                    } label: {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(CeptraTheme.hoverBG.opacity(0.75), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Screenshot Code Block (⌘⌥P · ⌥-Click or ⌘⌥⇧P for instant Quick Copy)")
                }
                .padding(.trailing, 10)
            }
        }
        .frame(height: 38)
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
    private func openTabsOverflowMenu(parentHints: [String?]) -> some View {
        let count = appState.openTabs.count
        Menu {
            Section("Open Tabs (\(count))") {
                ForEach(Array(appState.openTabs.enumerated()), id: \.element.filePath) { idx, tab in
                    let isActive = tab.filePath == appState.activeTabPath
                    let hint = parentHints.indices.contains(idx) ? parentHints[idx] : nil
                    let dirtyPrefix = tab.isDirty ? "● " : ""
                    let labelText = hint.map { "\(dirtyPrefix)\(tab.name) — \($0)" } ?? "\(dirtyPrefix)\(tab.name)"
                    Button {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                            appState.switchTab(to: tab.filePath)
                        }
                    } label: {
                        if isActive {
                            Label(labelText, systemImage: "checkmark")
                        } else {
                            Text(labelText)
                        }
                    }
                }
            }

            Divider()

            if let activePath = appState.activeTabPath {
                Button("Close Other Tabs") {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                        appState.closeOtherTabs(keeping: activePath)
                    }
                }
                .disabled(count < 2)
            }

            Button("Close Saved Tabs") {
                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                    appState.closeSavedTabs()
                }
            }
            .disabled(!appState.canCloseSavedTabs)

            Button("Close All Tabs") {
                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                    appState.closeAllTabs()
                }
            }

            if !appState.recentlyClosedTabPaths.isEmpty {
                Divider()
                Button("Reopen Closed Tab") {
                    appState.reopenLastClosedTab()
                }
            }

            if appState.hasDirtyTabs {
                Divider()
                Button("Save All Unsaved Tabs") {
                    appState.saveAllDirtyFiles()
                }
            }
        } label: {
            HStack(spacing: 3.5) {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textSecondary)
            }
            .padding(.horizontal, 6.5)
            .frame(height: 22)
            .background(CeptraTheme.hoverBG.opacity(0.75), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open Tabs (\(count)) & Tab Actions")
    }

    @ViewBuilder
    private func tabContextMenu(for tab: OpenDocumentTab, index: Int) -> some View {
        let total = appState.openTabs.count
        let hasOthers = total > 1
        let hasRight = index < total - 1
        let hasLeft = index > 0

        Button("Close") {
            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                appState.closeTab(filePath: tab.filePath)
            }
        }
        Button("Close Others") {
            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                appState.closeOtherTabs(keeping: tab.filePath)
            }
        }
        .disabled(!hasOthers)

        Button("Close Tabs to the Right") {
            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                appState.closeTabsToRight(of: tab.filePath)
            }
        }
        .disabled(!hasRight)

        Button("Close Tabs to the Left") {
            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                appState.closeTabsToLeft(of: tab.filePath)
            }
        }
        .disabled(!hasLeft)

        Button("Close Saved Tabs") {
            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                appState.closeSavedTabs()
            }
        }
        .disabled(!appState.canCloseSavedTabs)

        Button("Close All Tabs") {
            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                appState.closeAllTabs()
            }
        }

        if !appState.recentlyClosedTabPaths.isEmpty {
            Divider()
            Button("Reopen Closed Tab") {
                appState.reopenLastClosedTab()
            }
        }

        if tab.isDirty || appState.hasDirtyTabs {
            Divider()
            if tab.isDirty {
                Button("Save \"\(tab.name)\"") {
                    appState.saveTab(filePath: tab.filePath)
                }
            }
            if appState.openTabs.filter(\.isDirty).count > 1 || (!tab.isDirty && appState.hasDirtyTabs) {
                Button("Save All") {
                    appState.saveAllDirtyFiles()
                }
            }
        }

        if tab.isExecutableTestFile {
            Divider()
            Button("Run Test File") {
                appState.runTabFile(filePath: tab.filePath)
            }
            .disabled(appState.isRunning)

            Button("Debug Test File") {
                appState.debugTabFile(filePath: tab.filePath)
            }
            .disabled(appState.isRunning)
        }

        Divider()

        Button("Copy Relative Path") {
            appState.copyTextToPasteboard(tab.relativePath, label: "relative path")
        }
        Button("Copy Full Path") {
            appState.copyTextToPasteboard(tab.filePath, label: "full path")
        }

        Divider()

        Button("Reveal in Explorer") {
            appState.revealTabInExplorer(filePath: tab.filePath)
        }
        Button("Reveal in Finder") {
            appState.revealTabInFinder(filePath: tab.filePath)
        }
    }

    @ViewBuilder
    private func tabBarEmptyAreaContextMenu() -> some View {
        Button("Close Saved Tabs") {
            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                appState.closeSavedTabs()
            }
        }
        .disabled(!appState.canCloseSavedTabs)

        Button("Close All Tabs") {
            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                appState.closeAllTabs()
            }
        }
        .disabled(appState.openTabs.isEmpty)

        if !appState.recentlyClosedTabPaths.isEmpty {
            Divider()
            Button("Reopen Closed Tab") {
                appState.reopenLastClosedTab()
            }
        }

        if appState.hasDirtyTabs {
            Divider()
            Button("Save All") {
                appState.saveAllDirtyFiles()
            }
        }
    }

    @ViewBuilder
    private func tabCell(for tab: OpenDocumentTab, index: Int, parentHint: String?) -> some View {
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
            HStack(spacing: 6.5) {
                Text(tagInfo.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tagInfo.color)
                Text(tab.name)
                    .font(.system(size: 12.5, weight: (isActive || isDragged) ? .semibold : .medium))
                    .foregroundStyle(
                        (isActive || isDragged)
                            ? CeptraTheme.textPrimary
                            : (isHovered ? CeptraTheme.textPrimary.opacity(0.9) : CeptraTheme.textSecondary.opacity(0.85))
                    )
                    .lineLimit(1)
                if let parentHint {
                    Text(parentHint)
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted.opacity(0.85))
                        .lineLimit(1)
                }
                if tab.isDirty {
                    Circle()
                        .fill(CeptraTheme.accentWarm)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 2)
            .frame(height: 38)
            .contentShape(Rectangle())
            .help(appState.openTabs.count > 1 ? "\(tab.relativePath) — Drag to reorder · Right-click for options" : "\(tab.relativePath) — Right-click for options")
            .gesture(tabDragGesture(for: tab, index: index))

            Button {
                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                    appState.closeTab(filePath: tab.filePath)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isCloseHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                    .opacity(isActive || isHovered || isCloseHovered ? 1.0 : 0.55)
                    .frame(width: 20, height: 20)
                    .background(isCloseHovered ? CeptraTheme.hoverBG : Color.clear, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
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
        .contentShape(Rectangle())
        .contextMenu {
            tabContextMenu(for: tab, index: index)
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
            Text(
                appState.isPlaywrightPythonWorkspace
                    ? "Playwright Python Run Options"
                    : (appState.isPlaywrightWorkspace ? "Playwright Test Run Options" : "CodeceptJS 4.x Run Options")
            )
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

            if appState.isPlaywrightWorkspace {
                playwrightRunOptionsSection
            } else {
                codeceptRunOptionsSection
            }

            Divider().overlay(CeptraTheme.border)

            VStack(alignment: .leading, spacing: 8) {
                Text("Debug Mode")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accentWarm)

                Toggle(
                    appState.isPlaywrightWorkspace ? "Headed Browser (--headed)" : "Headed Browser (HEADLESS=false)",
                    isOn: $appState.runOptions.debugLaunchOptions.headedBrowser
                )
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
                    Label(appState.isPlaywrightWorkspace ? "Workers…" : "run-workers…", systemImage: "cpu")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 7, tint: CeptraTheme.panelBG, tintOpacity: 0.56))

                Button {
                    appState.showingRunOptionsPopover = false
                    appState.presentParallelRunSheet(tab: .multiple)
                } label: {
                    Label(appState.isPlaywrightWorkspace ? "Projects…" : "run-multiple…", systemImage: "square.stack.3d.up")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 7, tint: CeptraTheme.panelBG, tintOpacity: 0.56))
            }
        }
        .padding(16)
        .frame(width: 348)
        .background(CeptraTheme.panelBG)
        .onDisappear { appState.saveSettings() }
    }

    @ViewBuilder
    private var playwrightRunOptionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Headed Browser (--headed)", isOn: $appState.runOptions.playwrightHeaded)
            Toggle("Playwright Inspector (PWDEBUG=1)", isOn: $appState.runOptions.debug)
            Toggle("Bail on First Failure (--max-failures=1)", isOn: $appState.runOptions.bailOnFail)
            Toggle("Disable Timeouts (--timeout=0)", isOn: $appState.runOptions.noTimeouts)
            Toggle("Update Visual Snapshots (-u)", isOn: $appState.runOptions.playwrightUpdateSnapshots)
            Toggle("Capture Replay Trace (Steps, Shots & Console)", isOn: $appState.runOptions.timeTravelTrace)
                .disabled(appState.isSystemConsoleMode)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))

        if let projects = appState.workspace?.config.playwrightProjects, !projects.isEmpty {
            Divider().overlay(CeptraTheme.border)
            VStack(alignment: .leading, spacing: 6) {
                Text("Projects (--project)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textSecondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(projects, id: \.self) { proj in
                        let isSelected = appState.runOptions.playwrightSelectedProjects.contains(proj)
                        Toggle(proj, isOn: Binding(
                            get: { isSelected },
                            set: { checked in
                                if checked {
                                    if !appState.runOptions.playwrightSelectedProjects.contains(proj) {
                                        appState.runOptions.playwrightSelectedProjects.append(proj)
                                    }
                                } else {
                                    appState.runOptions.playwrightSelectedProjects.removeAll { $0 == proj }
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                }
            }
        }

        Divider().overlay(CeptraTheme.border)

        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Trace:")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CeptraTheme.textSecondary)
                Picker("", selection: $appState.runOptions.playwrightTraceMode) {
                    ForEach(PlaywrightTraceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
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
                        .help("Invert --grep matches (--grep-invert)")
                }
            }
            GridRow {
                Text("Workers:")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CeptraTheme.textSecondary)
                Stepper("\(appState.runOptions.workerCount)", value: $appState.runOptions.workerCount, in: 1...16)
                    .font(.system(size: 11.5))
            }
        }
    }

    @ViewBuilder
    private var codeceptRunOptionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show Steps (--steps)", isOn: $appState.runOptions.showSteps)
            Toggle("Debug Output (--debug)", isOn: $appState.runOptions.debug)
            Toggle("Verbose Logging (--verbose)", isOn: $appState.runOptions.verbose)
            Toggle("Enable AI Assistant (--ai)", isOn: $appState.runOptions.aiEnabled)
            Toggle("Bail on First Failure (--bail)", isOn: $appState.runOptions.bailOnFail)
            Toggle("Disable Timeouts (--no-timeouts)", isOn: $appState.runOptions.noTimeouts)
            Toggle("Capture Replay Trace (Web DOM/Shots & API HTTP)", isOn: $appState.runOptions.timeTravelTrace)
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
