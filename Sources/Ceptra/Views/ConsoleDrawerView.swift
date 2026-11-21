import AppKit
import CeptraCore
import SwiftUI

struct ConsoleDrawerView: View {
    static let headerHeight: CGFloat = 32

    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var bodyHeight: CGFloat = 220
    var isResizing: Bool = false

    @State private var filterMode: ConsoleFilterMode = .all
    @State private var searchText: String = ""
    @State private var pauseShellInput: String = ""
    @State private var isFilterSearchHovered = false
    @State private var isRecentHovered = false
    @FocusState private var isCommandFocused: Bool

    enum ConsoleFilterMode: String, CaseIterable, Identifiable {
        case all = "All"
        case steps = "Steps"
        case errors = "Errors"
        var id: String { rawValue }
    }

    var filteredLogs: [ConsoleLogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return appState.consoleLogs.filter { entry in
            switch filterMode {
            case .all: break
            case .steps: if !entry.isStep && !entry.isHighlight { return false }
            case .errors: if !entry.isError && !entry.text.contains("✖") && !entry.text.contains("FAIL") { return false }
            }
            if !query.isEmpty && !entry.text.lowercased().contains(query) { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Clean Matte 32pt Header Strip
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isRunning ? CeptraTheme.accent : CeptraTheme.success)
                        .frame(width: 6.5, height: 6.5)
                    Text(appState.isRunning ? "Running: \(appState.activeRunLabel)" : "Terminal & Logs")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .lineLimit(1)
                }

                HStack(spacing: 2) {
                    ForEach(ConsoleFilterMode.allCases) { mode in
                        let isSelected = filterMode == mode
                        Button {
                            filterMode = mode
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    isSelected ? CeptraTheme.activeBG : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextField("Filter logs…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isFilterSearchHovered ? CeptraTheme.borderStrong : CeptraTheme.border, lineWidth: 1)
                    )
                    .onHover { hovering in
                        isFilterSearchHovered = hovering
                    }
                    .frame(maxWidth: 150)

                Spacer()

                // Built-in vs System Console Switcher + Quick Launch
                CeptraGlassSegmentedControl(
                    options: ConsoleExecutionMode.allCases,
                    selection: Binding(
                        get: { appState.settings.consoleExecutionMode },
                        set: { appState.setConsoleExecutionMode($0) }
                    ),
                    label: { $0.shortName },
                    horizontalPadding: 8,
                    verticalPadding: 3.5,
                    fontSize: 10.5
                )
                .help(
                    appState.isSystemConsoleMode
                        ? "Running commands in system console (\(appState.activeTerminalDisplayName))"
                        : "Streaming commands inside Ceptra built-in console"
                )

                if appState.workspace != nil {
                    Button {
                        appState.openWorkspaceInSystemTerminal()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 11))
                            .foregroundStyle(appState.isSystemConsoleMode ? CeptraTheme.cyan : CeptraTheme.textSecondary)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(
                        CeptraGlassButtonStyle(
                            cornerRadius: 6,
                            tint: appState.isSystemConsoleMode ? CeptraTheme.cyan : CeptraTheme.panelBG,
                            tintOpacity: appState.isSystemConsoleMode ? 0.14 : 0.45,
                            accentBorder: appState.isSystemConsoleMode ? CeptraTheme.cyan : nil
                        )
                    )
                    .help("Open Workspace in \(appState.activeTerminalDisplayName) (⌘⇧T)")
                    .accessibilityLabel("Open Workspace in System Console")
                }

                // Quick Dependencies & Scripts Menu (npm / pnpm / yarn / bun)
                if let ws = appState.workspace {
                    let pm = ws.packageManager
                    CeptraGlassDropdown(arrowEdge: .top, minWidth: 270, maxWidth: 350) { isOpen in
                        CeptraMenuPillLabel(
                            title: pm.rawValue,
                            titleFont: .system(size: 10.5, weight: .semibold, design: .monospaced),
                            titleColor: CeptraTheme.accentWarm,
                            accentBorder: CeptraTheme.accentWarm,
                            tint: CeptraTheme.accentWarm,
                            tintOpacity: 0.14,
                            horizontalPadding: 8,
                            verticalPadding: 3.5,
                            cornerRadius: 6,
                            isOpen: isOpen
                        ) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 10.5))
                                .foregroundStyle(CeptraTheme.accentWarm)
                        }
                    } content: {
                        CeptraDropdownSectionHeader(title: "Dependencies (\(pm.rawValue))")
                        CeptraDropdownItem(
                            title: "Install Dependencies",
                            subtitle: PackageManagerSupport.commandPreview(for: .install, packageManager: pm),
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
                            title: "Clean Install",
                            subtitle: PackageManagerSupport.commandPreview(for: .cleanInstall, packageManager: pm),
                            systemImage: "sparkles"
                        ) {
                            appState.runDependencyAction(.cleanInstall)
                        }
                        CeptraDropdownItem(
                            title: "Check Outdated",
                            subtitle: PackageManagerSupport.commandPreview(for: .outdated, packageManager: pm),
                            systemImage: "clock.badge.exclamationmark"
                        ) {
                            appState.runDependencyAction(.outdated)
                        }

                        CeptraDropdownDivider()
                        CeptraDropdownSectionHeader(title: "CodeceptJS & Browsers")
                        CeptraDropdownItem(
                            title: "Update CodeceptJS",
                            subtitle: PackageManagerSupport.commandPreview(for: .upgradeCodeceptJS, packageManager: pm),
                            systemImage: "arrow.up.circle",
                            iconColor: CeptraTheme.accent
                        ) {
                            appState.runDependencyAction(.upgradeCodeceptJS)
                        }
                        CeptraDropdownItem(
                            title: "Install Playwright Browsers",
                            subtitle: PackageManagerSupport.commandPreview(for: .installPlaywrightBrowsers, packageManager: pm),
                            systemImage: "globe"
                        ) {
                            appState.runDependencyAction(.installPlaywrightBrowsers)
                        }

                        if !ws.packageScripts.isEmpty {
                            CeptraDropdownDivider()
                            CeptraDropdownSectionHeader(title: "package.json Scripts (\(ws.packageScripts.count))")
                            ForEach(ws.packageScripts) { script in
                                CeptraDropdownItem(
                                    title: script.name,
                                    subtitle: script.command,
                                    systemImage: "terminal",
                                    isMonospaced: true
                                ) {
                                    appState.runDependencyAction(.runScript(name: script.name))
                                }
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(appState.isRunning)
                    .help("Install / update dependencies or run package.json scripts")
                    .accessibilityLabel("Package Manager and Scripts")
                }

                if !appState.consoleLogs.isEmpty {
                    Button {
                        let full = appState.consoleLogs.map(\.text).joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(full, forType: .string)
                        appState.showBanner("Copied console output")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 6, tint: CeptraTheme.panelBG, tintOpacity: 0.45))
                    .help("Copy Logs")

                    Button {
                        appState.clearConsole()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 6, tint: CeptraTheme.panelBG, tintOpacity: 0.45))
                    .help("Clear Console")
                }

                Button {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion)) {
                        appState.toggleTerminal()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Hide Terminal & Logs (⌘J)")
                .accessibilityLabel("Hide Terminal")
            }
            .padding(.horizontal, 12)
            .frame(height: Self.headerHeight)
            .background(CeptraTheme.sidebarBG)
            .overlay(alignment: .top) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }

            // Smoothly animated drawer body: keeps fixed inner height so logs and input bar
            // glide smoothly without reflowing, squishing, or tearing down view state.
            VStack(spacing: 0) {
                // Streaming Log Area
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            let logFontSize = min(20.0, max(9.5, 11.5 * appState.editorZoomScale))
                            if filteredLogs.isEmpty {
                                Text("Ready. Press ⌘R to run tests, use the \(appState.workspace?.packageManager.rawValue ?? "npm") menu to update dependencies, or run any shell command below.")
                                    .font(.system(size: logFontSize, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.textMuted)
                                    .padding(12)
                            } else {
                                ForEach(filteredLogs) { entry in
                                    Text(entry.text)
                                        .font(.system(size: logFontSize, design: .monospaced))
                                        .foregroundStyle(lineColor(for: entry))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(entry.id)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: appState.consoleLogs.count) { _, _ in
                        if let last = filteredLogs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .background(CeptraTheme.canvasBG)

                // Interactive Workspace Command Prompt or Live CodeceptJS `pause()` Shell
                if appState.isInteractivePauseShellActive {
                    interactivePauseShellBar
                } else {
                    commandInputBar
                }
            }
            .frame(height: bodyHeight, alignment: .top)
            .opacity(appState.isConsoleVisible ? 1 : 0)
            .offset(y: appState.isConsoleVisible || reduceMotion ? 0 : 8)
            .frame(height: appState.isConsoleVisible ? bodyHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(appState.isConsoleVisible)
            .accessibilityHidden(!appState.isConsoleVisible)
            .animation(
                isResizing ? nil : CeptraMotion.resolve(CeptraMotion.panel, reduceMotion: reduceMotion),
                value: appState.isConsoleVisible
            )
        }
        .onChange(of: appState.focusCommandInputTrigger) { _, _ in
            isCommandFocused = true
        }
    }

    private var interactivePauseShellBar: some View {
        HStack(spacing: 8) {
            CeptraBadge(text: "pause() Shell", color: CeptraTheme.accentWarm, icon: "pause.circle.fill")

            TextField("Send I.* command or => expr to paused CodeceptJS shell…", text: $pauseShellInput)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(CeptraTheme.textPrimary)
                .focused($isCommandFocused)
                .onSubmit {
                    submitPauseShellCommand()
                }

            Button {
                appState.sendInteractiveShellCommand("")
            } label: {
                HStack(spacing: 3) {
                    Text("Next Step")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("↵")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(CeptraTheme.accentWarm)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(
                CeptraGlassButtonStyle(
                    cornerRadius: 6,
                    tint: CeptraTheme.accentWarm,
                    tintOpacity: 0.14,
                    accentBorder: CeptraTheme.accentWarm
                )
            )
            .help("Advance to next CodeceptJS step")

            Button {
                appState.sendInteractiveShellCommand("exit")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                    Text("Resume")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(CeptraTheme.success.opacity(0.90), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                )
            }
            .buttonStyle(CeptraTactilePressStyle())
            .help("Exit pause() shell and resume test execution")

            Button {
                submitPauseShellCommand()
            } label: {
                Image(systemName: "return")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(pauseShellInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CeptraTheme.textMuted : CeptraTheme.accentWarm)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(CeptraGlassButtonStyle(cornerRadius: 6, tint: CeptraTheme.panelBG, tintOpacity: 0.50))
            .help("Send Command to pause() Shell")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .ceptraGlassBar(tint: CeptraTheme.accentWarm, tintOpacity: 0.10, topHairline: true, bottomHairline: true)
    }

    private func submitPauseShellCommand() {
        let cmd = pauseShellInput
        pauseShellInput = ""
        appState.sendInteractiveShellCommand(cmd)
    }

    private var commandInputBar: some View {
        let pm = appState.workspace?.packageManager.rawValue ?? "npm"
        let sysMode = appState.isSystemConsoleMode
        let termName = appState.activeTerminalDisplayName
        return HStack(spacing: 8) {
            Text(sysMode ? "↗ $" : "$")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(sysMode ? CeptraTheme.cyan : CeptraTheme.accent)

            TextField(
                sysMode
                    ? "Run command in \(termName) (e.g. \(pm) update, npx playwright install)…"
                    : "Run workspace command (e.g. \(pm) update, \(pm) install -D codeceptjs@latest, npx playwright install)…",
                text: $appState.commandInputText
            )
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(CeptraTheme.textPrimary)
                .focused($isCommandFocused)
                .disabled(appState.workspace == nil || appState.isRunning)
                .onSubmit {
                    submitCustomCommand()
                }

            if !appState.commandHistory.isEmpty {
                CeptraGlassDropdown(arrowEdge: .top, minWidth: 260, maxWidth: 380) { isOpen in
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10.5))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(isOpen || isRecentHovered ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                            .offset(y: !isOpen && isRecentHovered && !reduceMotion ? 0.5 : 0)
                            .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: isOpen)
                    }
                    .foregroundStyle(isOpen || isRecentHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .ceptraGlassSurface(
                        cornerRadius: 6,
                        tint: CeptraTheme.panelBG,
                        tintOpacity: 0.56,
                        isHovered: isRecentHovered,
                        isActive: isOpen
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isRecentHovered)
                    .onHover { hovering in
                        isRecentHovered = hovering
                    }
                } content: {
                    CeptraDropdownSectionHeader(title: "Recent Commands")
                    ForEach(appState.commandHistory.prefix(12), id: \.self) { cmd in
                        CeptraDropdownItem(
                            title: cmd,
                            systemImage: "terminal",
                            isMonospaced: true
                        ) {
                            appState.commandInputText = cmd
                            appState.runDependencyAction(.customShell(command: cmd))
                        }
                    }
                }
                .fixedSize()
                .disabled(appState.isRunning)
                .help("Recent Commands")
                .accessibilityLabel("Recent Commands")
            }

            if appState.isRunning {
                Button {
                    appState.stopActiveRun()
                } label: {
                    Text("Stop")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(CeptraTheme.failure, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                        )
                }
                .buttonStyle(CeptraTactilePressStyle())
            } else {
                Button {
                    submitCustomCommand()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: sysMode ? "arrow.up.forward.app" : "return")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(sysMode ? termName : "Run")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(canRunInput ? .white : CeptraTheme.textMuted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        canRunInput ? (sysMode ? CeptraTheme.cyan : CeptraTheme.accent) : CeptraTheme.panelBG.opacity(0.65),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                canRunInput ? Color.white.opacity(0.24) : CeptraTheme.border,
                                lineWidth: 0.75
                            )
                    )
                }
                .buttonStyle(CeptraTactilePressStyle())
                .disabled(!canRunInput)
                .help(sysMode ? "Launch command in \(termName)" : "Run command in built-in console")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .ceptraGlassBar(tint: CeptraTheme.sidebarBG, tintOpacity: 0.74, topHairline: true, bottomHairline: true)
    }

    private var canRunInput: Bool {
        appState.workspace != nil
            && !appState.isRunning
            && !appState.commandInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitCustomCommand() {
        guard canRunInput else { return }
        appState.runDependencyAction(.customShell(command: appState.commandInputText))
    }

    private func lineColor(for entry: ConsoleLogEntry) -> Color {
        if entry.isError { return CeptraTheme.failure }
        let t = entry.text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("↗ ") { return CeptraTheme.cyan }
        if t.hasPrefix("$ ") { return CeptraTheme.accent }
        if t.hasPrefix("✔") || t.hasPrefix("OK |") { return CeptraTheme.success }
        if t.hasPrefix("✖") || t.hasPrefix("FAIL |") { return CeptraTheme.failure }
        if entry.isStep { return CeptraTheme.cyan.opacity(0.92) }
        return CeptraTheme.textPrimary.opacity(0.88)
    }
}
