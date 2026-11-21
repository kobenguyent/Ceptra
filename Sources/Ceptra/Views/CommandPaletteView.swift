import CeptraCore
import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    private struct PaletteItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let iconColor: Color
        let badge: String
        let action: () -> Void
    }

    private var filteredItems: [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = buildItems()
        guard !trimmed.isEmpty else { return Array(all.prefix(24)) }
        let tokens = trimmed.split(separator: " ").map(String.init)
        return all.filter { item in
            let hay = "\(item.title) \(item.subtitle) \(item.badge)".lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }
        .prefix(30)
        .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CeptraTheme.textMuted)
                TextField("Jump to file, scenario, or run a workspace command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .focused($isSearchFocused)
                    .onSubmit {
                        executeSelected()
                    }
                Text("ESC")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(CeptraTheme.hoverBG, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(CeptraTheme.border)

            let items = filteredItems
            if items.isEmpty {
                VStack(spacing: 6) {
                    Text("No matching files, scenarios, or actions")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                let isSelected = index == min(selectedIndex, max(0, items.count - 1))
                                Button {
                                    dismiss()
                                    item.action()
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: item.icon)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(item.iconColor)
                                            .frame(width: 18)

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title)
                                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                                .foregroundStyle(CeptraTheme.textPrimary)
                                                .lineLimit(1)
                                            if !item.subtitle.isEmpty {
                                                Text(item.subtitle)
                                                    .font(.system(size: 10.5, design: .monospaced))
                                                    .foregroundStyle(CeptraTheme.textMuted)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                        }

                                        Spacer(minLength: 8)

                                        Text(item.badge)
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundStyle(CeptraTheme.textMuted)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(CeptraTheme.hoverBG, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(isSelected ? CeptraTheme.activeBG : Color.clear)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selectedIndex) { _, newIdx in
                        if items.indices.contains(newIdx) {
                            proxy.scrollTo(items[newIdx].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 540)
        .background(CeptraTheme.panelBG)
        .onAppear {
            selectedIndex = 0
            isSearchFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.downArrow) {
            let count = filteredItems.count
            if count > 0 {
                selectedIndex = (selectedIndex + 1) % count
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            let count = filteredItems.count
            if count > 0 {
                selectedIndex = (selectedIndex - 1 + count) % count
            }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func executeSelected() {
        let items = filteredItems
        guard !items.isEmpty else { return }
        let idx = min(max(0, selectedIndex), items.count - 1)
        dismiss()
        items[idx].action()
    }

    private func buildItems() -> [PaletteItem] {
        var list: [PaletteItem] = []

        // 1. High-value workspace actions
        if appState.isActiveTabExecutableTestFile {
            list.append(PaletteItem(
                id: "act-run-active",
                title: "Run Active Test File",
                subtitle: appState.activeTab?.relativePath ?? "",
                icon: "play.fill",
                iconColor: CeptraTheme.success,
                badge: "⌘⇧R",
                action: { appState.runActiveFile() }
            ))
        }
        list.append(contentsOf: [
            PaletteItem(
                id: "act-run-all",
                title: "Run All Tests",
                subtitle: "Execute all CodeceptJS suites in workspace",
                icon: "play.circle.fill",
                iconColor: CeptraTheme.success,
                badge: "⌘R",
                action: { appState.run(mode: .runAll) }
            ),
            PaletteItem(
                id: "act-replay",
                title: "Open Replay Inspector",
                subtitle: "Step-by-step Visual, DOM, Network & Console player",
                icon: "clock.arrow.circlepath",
                iconColor: CeptraTheme.accent,
                badge: "⌘⌥T",
                action: { appState.openRightTab(.replay) }
            ),
            PaletteItem(
                id: "act-codecept-ui",
                title: "Open CodeceptUI Live",
                subtitle: "Launch embedded @codeceptjs/ui dashboard",
                icon: "macwindow",
                iconColor: CeptraTheme.violet,
                badge: "⌘⌥U",
                action: { appState.openRightTab(.codeceptUI) }
            ),
            PaletteItem(
                id: "act-outline",
                title: "Open Flow Outline",
                subtitle: "Hooks & scenario structure for active file",
                icon: "list.bullet.indent",
                iconColor: CeptraTheme.cyan,
                badge: "⌘⌥O",
                action: { appState.openRightTab(.outline) }
            ),
            PaletteItem(
                id: "act-debug",
                title: "Open Debug & Breakpoints",
                subtitle: "CDP inspector, call stack & locals",
                icon: "ladybug.fill",
                iconColor: CeptraTheme.accentWarm,
                badge: "⌘⌥J",
                action: { appState.openRightTab(.debug) }
            ),
            PaletteItem(
                id: "act-terminal",
                title: appState.isConsoleVisible ? "Hide Terminal & Logs" : "Show Terminal & Logs",
                subtitle: "Console output, npm scripts & interactive pause() shell",
                icon: "terminal",
                iconColor: CeptraTheme.success,
                badge: "⌘J",
                action: { appState.toggleTerminal() }
            ),
            PaletteItem(
                id: "act-reports",
                title: "Open Reports & Artifacts",
                subtitle: "Historical runs, JUnit XML & screenshots",
                icon: "chart.bar.doc.horizontal",
                iconColor: CeptraTheme.accent,
                badge: "Reports",
                action: { appState.showingReportsSheet = true }
            ),
            PaletteItem(
                id: "act-zoom-in",
                title: "Zoom In",
                subtitle: "Increase editor & console font size (currently \(appState.editorZoomPercentage)%)",
                icon: "plus.magnifyingglass",
                iconColor: CeptraTheme.accent,
                badge: "⌘+",
                action: { appState.zoomIn() }
            ),
            PaletteItem(
                id: "act-zoom-out",
                title: "Zoom Out",
                subtitle: "Decrease editor & console font size (currently \(appState.editorZoomPercentage)%)",
                icon: "minus.magnifyingglass",
                iconColor: CeptraTheme.accent,
                badge: "⌘−",
                action: { appState.zoomOut() }
            ),
            PaletteItem(
                id: "act-zoom-reset",
                title: "Reset Zoom to Actual Size (100%)",
                subtitle: "Restore default 13pt editor typography",
                icon: "1.magnifyingglass",
                iconColor: CeptraTheme.textSecondary,
                badge: "⌘0",
                action: { appState.resetZoom() }
            ),
            PaletteItem(
                id: "act-theme-toggle",
                title: appState.settings.appearance == .dark ? "Switch Theme to Paper Light" : "Switch Theme to Obsidian Dark",
                subtitle: "Toggle Ceptra studio appearance",
                icon: appState.settings.appearance == .dark ? "sun.max" : "moon.fill",
                iconColor: CeptraTheme.accentWarm,
                badge: "Theme",
                action: {
                    appState.settings.appearance = appState.settings.appearance == .dark ? .light : .dark
                    appState.saveSettings()
                }
            )
        ])

        // 2. Workspace files
        if let ws = appState.workspace {
            for file in ws.files {
                let badge: String
                let color: Color
                switch file.category {
                case .testSuite: badge = "Suite"; color = CeptraTheme.accent
                case .gherkinFeature: badge = "BDD"; color = CeptraTheme.violet
                case .pageObject: badge = "Page"; color = CeptraTheme.violet
                case .config: badge = "Config"; color = CeptraTheme.accentWarm
                case .helper: badge = "Helper"; color = CeptraTheme.cyan
                default: badge = file.fileExtension.uppercased(); color = CeptraTheme.textSecondary
                }
                list.append(PaletteItem(
                    id: "file-\(file.path)",
                    title: file.name,
                    subtitle: file.relativePath,
                    icon: file.category.symbolName,
                    iconColor: color,
                    badge: badge,
                    action: { appState.openFile(file) }
                ))
            }

            // 3. Individual scenarios
            for file in ws.testFiles {
                for feature in file.features {
                    for scenario in feature.scenarios {
                        list.append(PaletteItem(
                            id: "sc-\(file.path)-\(scenario.lineNumber)-\(scenario.title)",
                            title: scenario.cleanTitle,
                            subtitle: "\(file.relativePath):\(scenario.lineNumber)",
                            icon: "play.circle",
                            iconColor: CeptraTheme.color(for: appState.statusForScenario(scenario)),
                            badge: "Scenario",
                            action: { appState.openFile(file, jumpToLine: scenario.lineNumber) }
                        ))
                    }
                }
            }
        }

        return list
    }
}
