import CeptraCore
import SwiftUI

struct SidebarExplorerView: View {
    @EnvironmentObject var appState: AppState
    @State private var expandedFilePaths: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // Search + New File header
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                    TextField("Filter suites, scenarios, tags…", text: $appState.sidebarFilterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    if !appState.sidebarFilterText.isEmpty {
                        Button {
                            appState.sidebarFilterText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(CeptraTheme.border, lineWidth: 0.75))

                Button {
                    appState.showingNewFileSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(CeptraTheme.border, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .help("New CodeceptJS File (⌘N)")
            }
            .padding(10)

            // Tag filter strip
            if let tags = appState.workspace?.allTags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(tags, id: \.self) { tag in
                            let selected = appState.selectedTagFilter == tag
                            Button {
                                appState.selectedTagFilter = selected ? nil : tag
                            } label: {
                                Text(tag)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(selected ? .white : CeptraTheme.violet)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(selected ? CeptraTheme.violet : CeptraTheme.violet.opacity(0.14), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Run tests with \(tag)") {
                                    appState.run(mode: .runTag(tag: tag))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
            }

            Divider().overlay(CeptraTheme.border)

            // Categorized Explorer Tree
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let ws = appState.workspace {
                        testSuitesSection(files: filtered(ws.testFiles))

                        let support = filtered(ws.supportFiles)
                        if !support.isEmpty {
                            simpleFilesSection(title: "PAGES & STEPS", files: support)
                        }

                        let configs = filtered(ws.configAndHelperFiles)
                        if !configs.isEmpty {
                            simpleFilesSection(title: "CONFIG & HELPERS", files: configs)
                        }
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
            }

            Divider().overlay(CeptraTheme.border)

            // Minimalist Workspace Footer
            if let ws = appState.workspace {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ws.totalFeatureCount) suites · \(ws.totalScenarioCount) scenarios")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(CeptraTheme.textSecondary)
                        if let tc = appState.resolvedToolchain {
                            Text(tc.resolutionSource)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button {
                        appState.rescanWorkspace()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Rescan Workspace")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(CeptraTheme.panelBG.opacity(0.6))
            }
        }
        .background(CeptraTheme.sidebarBG)
        .onAppear {
            if let first = appState.workspace?.testFiles.first {
                expandedFilePaths.insert(first.path)
            }
        }
    }

    @ViewBuilder
    private func testSuitesSection(files: [WorkspaceFile]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SUITES & SCENARIOS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .tracking(0.7)
                Spacer()
                if let tag = appState.selectedTagFilter {
                    Button {
                        appState.run(mode: .runTag(tag: tag))
                    } label: {
                        Label("Run \(tag)", systemImage: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CeptraTheme.success)
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isRunning)
                }
            }
            .padding(.horizontal, 6)

            if files.isEmpty {
                Text("No matching test files")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else {
                ForEach(files) { file in
                    suiteFileRow(file)
                }
            }
        }
    }

    private func suiteFileRow(_ file: WorkspaceFile) -> some View {
        let isExpanded = expandedFilePaths.contains(file.path) || !appState.sidebarFilterText.isEmpty || appState.selectedTagFilter != nil
        let isActive = appState.activeTabPath == file.path
        let allScenarios = file.features.flatMap(\.scenarios)
        let matchingScenarios = allScenarios.filter { scenarioMatchesFilters($0) }

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    if expandedFilePaths.contains(file.path) {
                        expandedFilePaths.remove(file.path)
                    } else {
                        expandedFilePaths.insert(file.path)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                Image(systemName: file.category.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(file.category == .gherkinFeature ? CeptraTheme.violet : CeptraTheme.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                        .lineLimit(1)
                    if file.relativePath != file.name {
                        Text(file.relativePath)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Text("\(matchingScenarios.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(CeptraTheme.elevatedBG, in: Capsule())

                Button {
                    appState.run(mode: .runFile(relativePath: file.relativePath))
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(CeptraTheme.success)
                }
                .buttonStyle(.plain)
                .disabled(appState.isRunning)
                .help("Run \(file.name)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(isActive ? CeptraTheme.elevatedBG : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture {
                appState.openFile(file)
                expandedFilePaths.insert(file.path)
            }

            if isExpanded {
                ForEach(matchingScenarios) { scenario in
                    let status = appState.statusForScenario(scenario)
                    HStack(spacing: 6) {
                        StatusDotView(status: status, size: 7)
                        Text(scenario.cleanTitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(scenario.modifier == .skip ? CeptraTheme.textMuted : CeptraTheme.textPrimary.opacity(0.88))
                            .strikethrough(scenario.modifier == .skip)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if let ms = appState.durationForScenario(scenario) {
                            Text(ReportExporter.formatDuration(ms: ms))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }

                        Button {
                            appState.run(mode: .runScenario(relativePath: file.relativePath, scenarioTitle: scenario.cleanTitle))
                        } label: {
                            Image(systemName: "play")
                                .font(.system(size: 9))
                                .foregroundStyle(CeptraTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isRunning)
                        .help("Run scenario \"\(scenario.cleanTitle)\"")
                    }
                    .padding(.leading, 24)
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.openFile(file, jumpToLine: scenario.lineNumber)
                    }
                }
            }
        }
    }

    private func simpleFilesSection(title: String, files: [WorkspaceFile]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(CeptraTheme.textMuted)
                .tracking(0.7)
                .padding(.horizontal, 6)

            ForEach(files) { file in
                let isActive = appState.activeTabPath == file.path
                HStack(spacing: 7) {
                    Image(systemName: file.category.symbolName)
                        .font(.system(size: 11))
                        .foregroundStyle(file.category == .config ? CeptraTheme.accentWarm : CeptraTheme.textMuted)
                    Text(file.relativePath)
                        .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isActive ? CeptraTheme.elevatedBG : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.openFile(file)
                }
            }
        }
    }

    private func filtered(_ files: [WorkspaceFile]) -> [WorkspaceFile] {
        let query = appState.sidebarFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tag = appState.selectedTagFilter

        return files.filter { file in
            if let tag {
                guard file.allTags.contains(tag) else { return false }
            }
            if query.isEmpty { return true }
            if file.relativePath.lowercased().contains(query) { return true }
            return file.features.contains { feature in
                feature.title.lowercased().contains(query) ||
                feature.scenarios.contains { $0.title.lowercased().contains(query) }
            }
        }
    }

    private func scenarioMatchesFilters(_ scenario: ParsedScenario) -> Bool {
        if let tag = appState.selectedTagFilter, !scenario.tags.contains(tag) {
            return false
        }
        let query = appState.sidebarFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return true }
        return scenario.title.lowercased().contains(query) || scenario.featureTitle.lowercased().contains(query)
    }
}
