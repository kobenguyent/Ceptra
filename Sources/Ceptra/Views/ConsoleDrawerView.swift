import AppKit
import CeptraCore
import SwiftUI

struct ConsoleDrawerView: View {
    @EnvironmentObject var appState: AppState
    @State private var filterMode: ConsoleFilterMode = .all
    @State private var searchText: String = ""
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
            // Header Strip
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isRunning ? CeptraTheme.accent : CeptraTheme.textMuted)
                        .frame(width: 7, height: 7)
                    Text(appState.isRunning ? "Running: \(appState.activeRunLabel)" : "Console & Commands")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .lineLimit(1)
                }

                Picker("", selection: $filterMode) {
                    ForEach(ConsoleFilterMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 168)

                TextField("Filter logs…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 5))
                    .frame(maxWidth: 160)

                Spacer()

                // Quick Dependencies & Scripts Menu (npm / pnpm / yarn / bun)
                if let ws = appState.workspace {
                    let pm = ws.packageManager
                    Menu {
                        Section("Dependencies (\(pm.rawValue))") {
                            Button("Install Dependencies (\(PackageManagerSupport.commandPreview(for: .install, packageManager: pm)))") {
                                appState.runDependencyAction(.install)
                            }
                            Button("Update Dependencies (\(PackageManagerSupport.commandPreview(for: .update, packageManager: pm)))") {
                                appState.runDependencyAction(.update)
                            }
                            Button("Clean Install (\(PackageManagerSupport.commandPreview(for: .cleanInstall, packageManager: pm)))") {
                                appState.runDependencyAction(.cleanInstall)
                            }
                            Button("Check Outdated (\(PackageManagerSupport.commandPreview(for: .outdated, packageManager: pm)))") {
                                appState.runDependencyAction(.outdated)
                            }
                        }

                        Divider()

                        Section("CodeceptJS & Browsers") {
                            Button("Update CodeceptJS (\(PackageManagerSupport.commandPreview(for: .upgradeCodeceptJS, packageManager: pm)))") {
                                appState.runDependencyAction(.upgradeCodeceptJS)
                            }
                            Button("Install Playwright Browsers (\(PackageManagerSupport.commandPreview(for: .installPlaywrightBrowsers, packageManager: pm)))") {
                                appState.runDependencyAction(.installPlaywrightBrowsers)
                            }
                        }

                        if !ws.packageScripts.isEmpty {
                            Divider()
                            Menu("package.json Scripts (\(ws.packageScripts.count))") {
                                ForEach(ws.packageScripts) { script in
                                    Button("\(script.name)  —  \(script.command)") {
                                        appState.runDependencyAction(.runScript(name: script.name))
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 10.5))
                            Text(pm.rawValue)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        .foregroundStyle(CeptraTheme.accentWarm)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(CeptraTheme.accentWarm.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(CeptraTheme.accentWarm.opacity(0.28), lineWidth: 0.75))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(appState.isRunning)
                    .help("Install / update dependencies or run package.json scripts")
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
                    }
                    .buttonStyle(.plain)
                    .help("Copy Logs")

                    Button {
                        appState.clearConsole()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Console")
                }

                Button {
                    appState.isConsoleVisible = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Hide Console (⌘J)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(CeptraTheme.sidebarBG)

            Divider().overlay(CeptraTheme.border)

            // Streaming Log Area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if filteredLogs.isEmpty {
                            Text("Ready. Press ⌘R to run tests, use the \(appState.workspace?.packageManager.rawValue ?? "npm") menu to update dependencies, or run any shell command below.")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textMuted)
                                .padding(12)
                        } else {
                            ForEach(filteredLogs) { entry in
                                Text(entry.text)
                                    .font(.system(size: 11.5, design: .monospaced))
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
            .background(Color(red: 0.058, green: 0.064, blue: 0.080))

            Divider().overlay(CeptraTheme.border)

            // Interactive Workspace Command Prompt (npm update, npm install <pkg>, npx ..., etc.)
            commandInputBar
        }
        .onChange(of: appState.focusCommandInputTrigger) { _, _ in
            isCommandFocused = true
        }
    }

    private var commandInputBar: some View {
        let pm = appState.workspace?.packageManager.rawValue ?? "npm"
        return HStack(spacing: 8) {
            Text("$")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(CeptraTheme.accent)

            TextField("Run workspace command (e.g. \(pm) update, \(pm) install -D codeceptjs@latest, npx playwright install)…", text: $appState.commandInputText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(CeptraTheme.textPrimary)
                .focused($isCommandFocused)
                .disabled(appState.workspace == nil || appState.isRunning)
                .onSubmit {
                    submitCustomCommand()
                }

            if !appState.commandHistory.isEmpty {
                Menu {
                    ForEach(appState.commandHistory.prefix(12), id: \.self) { cmd in
                        Button(cmd) {
                            appState.commandInputText = cmd
                            appState.runDependencyAction(.customShell(command: cmd))
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(appState.isRunning)
                .help("Recent Commands")
            }

            if appState.isRunning {
                Button {
                    appState.stopActiveRun()
                } label: {
                    Text("Stop")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(CeptraTheme.failure, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    submitCustomCommand()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "return")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("Run")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(canRunInput ? .white : CeptraTheme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(canRunInput ? CeptraTheme.accent : CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(!canRunInput)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(CeptraTheme.sidebarBG)
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
        if t.hasPrefix("$ ") { return CeptraTheme.accent }
        if t.hasPrefix("✔") || t.hasPrefix("OK |") { return CeptraTheme.success }
        if t.hasPrefix("✖") || t.hasPrefix("FAIL |") { return CeptraTheme.failure }
        if entry.isStep { return CeptraTheme.cyan.opacity(0.92) }
        return CeptraTheme.textPrimary.opacity(0.88)
    }
}
