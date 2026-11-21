import CeptraCore
import SwiftUI

// MARK: - Floating Debug Control Bar

struct DebugFloatingControlBar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            statusPill

            Divider()
                .frame(height: 16)
                .overlay(CeptraTheme.border)

            HStack(spacing: 4) {
                DebugBarIconButton(
                    systemImage: "play.fill",
                    tint: CeptraTheme.success,
                    helpText: "Continue (F5)",
                    isDisabled: !appState.debugPhase.isPaused
                ) {
                    appState.debugContinue()
                }

                DebugBarIconButton(
                    systemImage: "pause.fill",
                    tint: CeptraTheme.accentWarm,
                    helpText: "Pause Execution",
                    isDisabled: appState.debugPhase != .running
                ) {
                    appState.debugPause()
                }

                DebugBarIconButton(
                    systemImage: "arrow.uturn.right",
                    tint: CeptraTheme.accent,
                    helpText: "Step Over (F10)",
                    isDisabled: !appState.debugPhase.isPaused
                ) {
                    appState.debugStepOver()
                }

                DebugBarIconButton(
                    systemImage: "arrow.down.to.line",
                    tint: CeptraTheme.accent,
                    helpText: "Step Into (F11)",
                    isDisabled: !appState.debugPhase.isPaused
                ) {
                    appState.debugStepInto()
                }

                DebugBarIconButton(
                    systemImage: "arrow.up.to.line",
                    tint: CeptraTheme.accent,
                    helpText: "Step Out (⇧F11)",
                    isDisabled: !appState.debugPhase.isPaused
                ) {
                    appState.debugStepOut()
                }
            }

            Divider()
                .frame(height: 16)
                .overlay(CeptraTheme.border)

            HStack(spacing: 4) {
                DebugBarIconButton(
                    systemImage: "arrow.clockwise",
                    tint: CeptraTheme.cyan,
                    helpText: "Restart Debug Session",
                    isDisabled: appState.debugPhase == .stopping
                ) {
                    appState.restartDebugSession()
                }

                DebugBarIconButton(
                    systemImage: "stop.fill",
                    tint: CeptraTheme.failure,
                    helpText: "Stop Debug Session (⌘.)",
                    isDisabled: appState.debugPhase == .stopping
                ) {
                    appState.stopActiveRun()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .ceptraGlassSurface(
            cornerRadius: 12,
            tint: CeptraTheme.elevatedBG,
            tintOpacity: 0.78,
            accentBorder: barAccentColor,
            elevatedShadow: true
        )
        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: appState.debugPhase)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            if appState.debugPhase == .launching || appState.debugPhase == .stopping {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusDotColor.opacity(0.75), radius: 3)
            }

            Text(statusLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(CeptraTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
        }
        .padding(.horizontal, 4)
    }

    private var statusDotColor: Color {
        switch appState.debugPhase {
        case .idle: return CeptraTheme.textMuted
        case .launching: return CeptraTheme.accent
        case .running: return CeptraTheme.success
        case .paused: return CeptraTheme.accentWarm
        case .interactiveShell: return CeptraTheme.accentWarm
        case .stopping: return CeptraTheme.failure
        }
    }

    private var barAccentColor: Color? {
        switch appState.debugPhase {
        case .paused, .interactiveShell: return CeptraTheme.accentWarm
        case .running: return CeptraTheme.success
        case .launching: return CeptraTheme.accent
        default: return nil
        }
    }

    private var statusLabel: String {
        switch appState.debugPhase {
        case .idle:
            return "Idle"
        case .launching:
            return "Launching…"
        case .running:
            return "Running"
        case .paused(let reason):
            if let loc = appState.pausedLocation, !loc.filePath.isEmpty {
                return "Paused · \(loc.fileName):\(loc.line)"
            }
            return reason.isEmpty ? "Paused" : "Paused · \(reason)"
        case .interactiveShell:
            return "CodeceptJS Shell"
        case .stopping:
            return "Stopping…"
        }
    }
}

private struct DebugBarIconButton: View {
    let systemImage: String
    let tint: Color
    let helpText: String
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isDisabled ? CeptraTheme.textMuted.opacity(0.42) : (isHovered ? tint : tint.opacity(0.88)))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered && !isDisabled ? tint.opacity(0.16) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isHovered && !isDisabled ? tint.opacity(0.35) : Color.clear, lineWidth: 0.7)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.92))
        .disabled(isDisabled)
        .help(helpText)
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Debug Inspector Panel

private enum DebugInspectorSection: String, CaseIterable, Identifiable {
    case variables = "Vars"
    case watch = "Watch"
    case breakpoints = "Breaks"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .variables: return "list.bullet.indent"
        case .watch: return "eye"
        case .breakpoints: return "circle.inset.filled"
        }
    }
}

struct DebugInspectorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var activeSection: DebugInspectorSection = .variables
    @State private var watchExpressionInput: String = ""
    @State private var evalExpressionInput: String = ""
    @State private var isWatchInputHovered = false
    @State private var isEvalInputHovered = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            // Segmented Section Switcher
            HStack {
                CeptraGlassSegmentedControl(
                    options: DebugInspectorSection.allCases,
                    selection: $activeSection,
                    label: { $0.rawValue },
                    symbol: { $0.symbolName },
                    badgeCount: { section in
                        switch section {
                        case .variables:
                            return appState.visibleCallFrames.isEmpty ? nil : appState.visibleCallFrames.count
                        case .watch:
                            return appState.debugWatchItems.isEmpty ? nil : appState.debugWatchItems.count
                        case .breakpoints:
                            return appState.breakpoints.isEmpty ? nil : appState.breakpoints.count
                        }
                    },
                    horizontalPadding: 8,
                    verticalPadding: 4,
                    fontSize: 10.5
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .ceptraGlassBar(tint: CeptraTheme.sidebarBG, tintOpacity: 0.56, bottomHairline: true)

            // Main Section Content
            Group {
                switch activeSection {
                case .variables:
                    variablesAndCallStackSection
                case .watch:
                    watchSection
                case .breakpoints:
                    breakpointsSection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom Debug Eval Console Strip
            debugEvalConsoleStrip
        }
        .background(CeptraTheme.sidebarBG)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(CeptraTheme.border)
                .frame(width: 0.75)
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(appState.debugPhase.isActive ? CeptraTheme.accentWarm : CeptraTheme.accent)

            Text("Debug Inspector")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CeptraTheme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            // Exception Breakpoints Menu
            CeptraGlassDropdown(arrowEdge: .bottom, minWidth: 200, maxWidth: 240) { isOpen in
                let mode = appState.runOptions.debugLaunchOptions.breakOnExceptions
                CeptraMenuPillLabel(
                    title: shortExceptionLabel(mode),
                    titleFont: .system(size: 10, weight: .medium),
                    titleColor: mode == .none ? CeptraTheme.textSecondary : CeptraTheme.accentWarm,
                    accentBorder: mode == .none ? nil : CeptraTheme.accentWarm,
                    tint: mode == .none ? CeptraTheme.panelBG : CeptraTheme.accentWarm,
                    tintOpacity: mode == .none ? 0.50 : 0.14,
                    horizontalPadding: 7,
                    verticalPadding: 3,
                    cornerRadius: 6,
                    isOpen: isOpen
                ) {
                    Image(systemName: "exclamationmark.octagon")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(mode == .none ? CeptraTheme.textMuted : CeptraTheme.accentWarm)
                }
            } content: {
                CeptraDropdownSectionHeader(title: "Exception Breakpoints")
                ForEach(ExceptionBreakMode.allCases) { mode in
                    CeptraDropdownItem(
                        title: mode.displayName,
                        systemImage: mode == .none ? "nosign" : "exclamationmark.octagon.fill",
                        iconColor: mode == .none ? CeptraTheme.textMuted : CeptraTheme.accentWarm,
                        isSelected: appState.runOptions.debugLaunchOptions.breakOnExceptions == mode
                    ) {
                        appState.setExceptionBreakMode(mode)
                    }
                }
            }
            .fixedSize()
            .help("Exception Breakpoints")

            Button {
                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                    appState.isDebugInspectorVisible = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 6, tint: CeptraTheme.panelBG, tintOpacity: 0.45))
            .help("Close Debug Inspector")
            .accessibilityLabel("Close Debug Inspector")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .ceptraGlassBar(tint: CeptraTheme.sidebarBG, tintOpacity: 0.72, bottomHairline: true)
    }

    private func shortExceptionLabel(_ mode: ExceptionBreakMode) -> String {
        switch mode {
        case .none: return "Off"
        case .uncaught: return "Uncaught"
        case .all: return "All"
        }
    }

    // MARK: - Section 1: Variables & Call Stack

    private var variablesAndCallStackSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Call Stack Card
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("CALL STACK")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(CeptraTheme.textMuted)

                        Spacer()

                        Toggle("Just My Code", isOn: $appState.debugJustMyCode)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .controlSize(.mini)
                    }

                    if appState.visibleCallFrames.isEmpty {
                        emptyHint(
                            icon: "pause.circle",
                            text: appState.debugPhase.isActive
                                ? "Running — pause or hit a breakpoint to inspect stack frames."
                                : "Start a debug session to inspect call stack."
                        )
                    } else {
                        VStack(spacing: 2) {
                            ForEach(appState.visibleCallFrames) { frame in
                                CallFrameRow(
                                    frame: frame,
                                    isSelected: frame.id == appState.selectedCallFrame?.id
                                ) {
                                    appState.selectCallFrame(frame)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .ceptraGlassSurface(cornerRadius: 10, tint: CeptraTheme.panelBG, tintOpacity: 0.52)

                // Scopes & Variables Card
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("SCOPES & VARIABLES")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(CeptraTheme.textMuted)
                        Spacer()
                        if let frame = appState.selectedCallFrame {
                            Text(frame.functionName)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(CeptraTheme.accent)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    if let frame = appState.selectedCallFrame {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(frame.scopes) { scope in
                                DebugScopeDisclosureView(
                                    title: scope.name,
                                    subtitle: scope.type,
                                    objectId: scope.objectId,
                                    defaultExpanded: scope.type == "local" || scope.type == "block"
                                )
                            }

                            if let thisObjectId = frame.thisObjectId {
                                DebugScopeDisclosureView(
                                    title: "this",
                                    subtitle: "object",
                                    objectId: thisObjectId,
                                    defaultExpanded: false
                                )
                            }
                        }
                    } else {
                        emptyHint(
                            icon: "curlybraces",
                            text: "No active call frame selected."
                        )
                    }
                }
                .padding(10)
                .ceptraGlassSurface(cornerRadius: 10, tint: CeptraTheme.panelBG, tintOpacity: 0.52)
            }
            .padding(10)
        }
    }

    // MARK: - Section 2: Watch

    private var watchSection: some View {
        VStack(spacing: 0) {
            // Add Watch Input
            HStack(spacing: 6) {
                TextField("Add watch expression…", text: $watchExpressionInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .ceptraGlassSurface(
                        cornerRadius: 7,
                        tint: CeptraTheme.panelBG,
                        tintOpacity: 0.58,
                        isHovered: isWatchInputHovered
                    )
                    .onHover { isWatchInputHovered = $0 }
                    .onSubmit {
                        submitWatchExpression()
                    }

                Button {
                    submitWatchExpression()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.accent)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 6, tint: CeptraTheme.accent, tintOpacity: 0.14, accentBorder: CeptraTheme.accent))
                .disabled(watchExpressionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add Watch Expression")

                if appState.debugPhase.isPaused && !appState.debugWatchItems.isEmpty {
                    Button {
                        appState.refreshWatchExpressions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 6, tint: CeptraTheme.panelBG, tintOpacity: 0.50))
                    .help("Refresh Watch Expressions")
                }
            }
            .padding(10)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if appState.debugWatchItems.isEmpty {
                        emptyHint(
                            icon: "eye",
                            text: "Add JS expressions to watch their live values whenever execution pauses."
                        )
                        .padding(10)
                        .ceptraGlassSurface(cornerRadius: 10, tint: CeptraTheme.panelBG, tintOpacity: 0.45)
                    } else {
                        ForEach(appState.debugWatchItems) { item in
                            WatchItemRow(item: item) {
                                appState.removeWatchItem(id: item.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    private func submitWatchExpression() {
        let trimmed = watchExpressionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.addWatchExpression(trimmed)
        watchExpressionInput = ""
    }

    // MARK: - Section 3: Breakpoints

    private var breakpointsSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("BREAKPOINTS (\(appState.breakpoints.count))")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(CeptraTheme.textMuted)

                Spacer()

                if !appState.breakpoints.isEmpty {
                    Button {
                        appState.clearAllBreakpoints()
                    } label: {
                        Text("Clear All")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(CeptraTheme.failure)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 6, tint: CeptraTheme.failure, tintOpacity: 0.12, accentBorder: CeptraTheme.failure))
                    .help("Remove all breakpoints")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if appState.breakpoints.isEmpty {
                        emptyHint(
                            icon: "circle.inset.filled",
                            text: "Click the editor gutter to toggle line breakpoints, or right-click for conditional breakpoints & logpoints."
                        )
                        .padding(10)
                        .ceptraGlassSurface(cornerRadius: 10, tint: CeptraTheme.panelBG, tintOpacity: 0.45)
                    } else {
                        ForEach(appState.breakpoints) { bp in
                            BreakpointRow(
                                breakpoint: bp,
                                onToggleEnabled: {
                                    appState.toggleBreakpointEnabled(id: bp.id)
                                },
                                onJump: {
                                    appState.openFileByURL(URL(fileURLWithPath: bp.filePath), jumpToLine: bp.line)
                                },
                                onDelete: {
                                    appState.removeBreakpoint(id: bp.id)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }

    // MARK: - Bottom Debug Eval Console Strip

    private var debugEvalConsoleStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accent)
                Text("DEBUG EVAL")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(CeptraTheme.textMuted)
                Spacer()
                if !appState.debugConsoleEntries.isEmpty {
                    Button {
                        appState.debugConsoleEntries.removeAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9.5))
                            .foregroundStyle(CeptraTheme.textMuted)
                            .frame(width: 20, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Debug Eval Output")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .ceptraGlassBar(tint: CeptraTheme.panelBG, tintOpacity: 0.65, topHairline: true, bottomHairline: true)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if appState.debugConsoleEntries.isEmpty {
                            Text(appState.debugPhase.isActive ? "Evaluate JS in the active frame below." : "Start a debug session to evaluate expressions.")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textMuted)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(appState.debugConsoleEntries) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .top, spacing: 4) {
                                        Text(">")
                                            .foregroundStyle(CeptraTheme.accent)
                                        Text(entry.expression)
                                            .foregroundStyle(CeptraTheme.textSecondary)
                                    }
                                    .font(.system(size: 10.5, design: .monospaced))

                                    Text(entry.result)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(entry.isError ? CeptraTheme.failure : CeptraTheme.textPrimary)
                                        .textSelection(.enabled)
                                        .padding(.leading, 10)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(height: 112)
                .background(Color(red: 0.058, green: 0.064, blue: 0.080))
                .onChange(of: appState.debugConsoleEntries.count) { _, _ in
                    if let last = appState.debugConsoleEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 6) {
                Text(">")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(appState.debugPhase.isActive ? CeptraTheme.accent : CeptraTheme.textMuted)

                TextField(
                    appState.debugPhase.isActive ? "Evaluate expression…" : "Debugger inactive",
                    text: $evalExpressionInput
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(CeptraTheme.textPrimary)
                .disabled(!appState.debugPhase.isActive)
                .onSubmit {
                    submitEvalExpression()
                }

                Button {
                    submitEvalExpression()
                } label: {
                    Image(systemName: "return")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(canSubmitEval ? CeptraTheme.accent : CeptraTheme.textMuted.opacity(0.45))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitEval)
                .help("Evaluate Expression")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isEvalInputHovered ? CeptraTheme.glassHoverOverlay : Color.clear)
            .ceptraGlassBar(tint: CeptraTheme.sidebarBG, tintOpacity: 0.78, topHairline: true)
            .onHover { isEvalInputHovered = $0 }
        }
    }

    private var canSubmitEval: Bool {
        appState.debugPhase.isActive && !evalExpressionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitEvalExpression() {
        let trimmed = evalExpressionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, appState.debugPhase.isActive else { return }
        appState.evaluateDebugExpression(trimmed)
        evalExpressionInput = ""
    }

    private func emptyHint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11.5))
                .foregroundStyle(CeptraTheme.textMuted)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(CeptraTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

// MARK: - Subviews

private struct CallFrameRow: View {
    let frame: DebugCallFrame
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? CeptraTheme.accentWarm : Color.clear)
                    .frame(width: 6, height: 6)

                Text(frame.functionName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .monospaced))
                    .foregroundStyle(
                        frame.isInternal
                            ? CeptraTheme.textMuted
                            : (isSelected ? CeptraTheme.textPrimary : CeptraTheme.textPrimary.opacity(0.88))
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                if !frame.location.filePath.isEmpty {
                    Text("\(frame.location.fileName):\(frame.location.line)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(isSelected ? CeptraTheme.accentWarm : CeptraTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(CeptraTheme.accentWarm.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(CeptraTheme.accentWarm.opacity(0.32), lineWidth: 0.7)
                        )
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(CeptraTheme.glassHoverOverlay)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct DebugScopeDisclosureView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let subtitle: String
    let objectId: String
    let defaultExpanded: Bool

    @State private var isExpanded: Bool = false
    @State private var didInitialize = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
                if isExpanded {
                    appState.loadVariables(forObjectId: objectId)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)

                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)

                    if subtitle.lowercased() != title.lowercased() {
                        Text(subtitle)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }

                    Spacer()

                    if let vars = appState.debugScopeVariables[objectId] {
                        Text("\(vars.count)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let vars = appState.debugScopeVariables[objectId] {
                    if vars.isEmpty {
                        Text("(empty)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                            .padding(.leading, 18)
                            .padding(.vertical, 2)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(vars) { variable in
                                DebugVariableRow(variable: variable, depth: 0)
                            }
                        }
                        .padding(.leading, 10)
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).scaleEffect(0.6)
                        Text("Loading…")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    .padding(.leading, 18)
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear {
            if !didInitialize {
                didInitialize = true
                isExpanded = defaultExpanded
                if defaultExpanded {
                    appState.loadVariables(forObjectId: objectId)
                }
            }
        }
    }
}

private struct DebugVariableRow: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let variable: DebugVariable
    let depth: Int

    @State private var isExpanded = false

    private static let maxDepth = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                if variable.isExpandable && depth < Self.maxDepth {
                    Button {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                            isExpanded.toggle()
                        }
                        if isExpanded, let objId = variable.objectId {
                            appState.loadVariables(forObjectId: objId)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textMuted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 14)
                }

                Text(variable.name)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .lineLimit(1)

                Text(":")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)

                Text(variable.value)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(debugValueColor(type: variable.type, subtype: variable.subtype))
                    .lineLimit(2)
                    .textSelection(.enabled)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 1.5)

            if isExpanded, let objId = variable.objectId, depth < Self.maxDepth {
                if let children = appState.debugScopeVariables[objId] {
                    if children.isEmpty {
                        Text("(no properties)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                            .padding(.leading, 18)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(children) { child in
                                DebugVariableRow(variable: child, depth: depth + 1)
                            }
                        }
                        .padding(.leading, 14)
                    }
                } else {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini).scaleEffect(0.55)
                        Text("Loading…")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    .padding(.leading, 18)
                }
            }
        }
    }
}

private struct WatchItemRow: View {
    let item: DebugWatchItem
    let onRemove: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.expression)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .lineLimit(2)

                Text(item.value)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(item.isError ? CeptraTheme.failure : debugValueColor(type: item.type, subtype: nil))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 4)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isHovered ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.65)
            .help("Remove Watch Expression")
        }
        .padding(8)
        .ceptraGlassSurface(
            cornerRadius: 8,
            tint: CeptraTheme.panelBG,
            tintOpacity: 0.52,
            isHovered: isHovered
        )
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct BreakpointRow: View {
    let breakpoint: DebugBreakpoint
    let onToggleEnabled: () -> Void
    let onJump: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fileName: String {
        URL(fileURLWithPath: breakpoint.filePath).lastPathComponent
    }

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Button(action: onToggleEnabled) {
                Image(systemName: breakpoint.isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(
                        breakpoint.isEnabled
                            ? (breakpoint.isLogpoint ? CeptraTheme.cyan : (breakpoint.isConditional ? CeptraTheme.accentWarm : CeptraTheme.failure))
                            : CeptraTheme.textMuted
                    )
            }
            .buttonStyle(.plain)
            .help(breakpoint.isEnabled ? "Disable Breakpoint" : "Enable Breakpoint")

            Button(action: onJump) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(fileName)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(breakpoint.isEnabled ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(":\(breakpoint.line)")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CeptraTheme.accent)
                    }

                    if let logMessage = breakpoint.logMessage {
                        CeptraBadge(text: "log: \(logMessage)", color: CeptraTheme.cyan, icon: "text.bubble")
                    } else if let condition = breakpoint.condition {
                        CeptraBadge(text: "if \(condition)", color: CeptraTheme.accentWarm, icon: "questionmark.diamond")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(breakpoint.filePath):\(breakpoint.line)")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(isHovered ? CeptraTheme.failure : CeptraTheme.textMuted)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0.65)
            .help("Remove Breakpoint")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .ceptraGlassSurface(
            cornerRadius: 8,
            tint: CeptraTheme.panelBG,
            tintOpacity: breakpoint.isEnabled ? 0.54 : 0.34,
            isHovered: isHovered
        )
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private func debugValueColor(type: String, subtype: String?) -> Color {
    if subtype == "null" {
        return CeptraTheme.textMuted
    }
    switch type {
    case "string":
        return CeptraTheme.accentWarm
    case "number", "bigint":
        return CeptraTheme.violet
    case "boolean":
        return CeptraTheme.cyan
    case "function", "undefined", "symbol":
        return CeptraTheme.textMuted
    default:
        return CeptraTheme.textPrimary
    }
}
