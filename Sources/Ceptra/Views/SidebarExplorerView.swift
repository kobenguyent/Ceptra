import AppKit
import CeptraCore
import SwiftUI

struct SidebarExplorerView: View {
    @EnvironmentObject var appState: AppState
    @State private var explorerMode: ExplorerMode = .projectTree
    @State private var expandedFolders: Set<String> = []
    @State private var expandedTestFiles: Set<String> = []
    @State private var showHiddenEntries: Bool = true
    @State private var lastInitializedRootPath: String = ""

    enum ExplorerMode: String, CaseIterable, Identifiable {
        case projectTree = "Project"
        case testSuites = "Suites"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .projectTree: return "folder.fill"
            case .testSuites: return "checkmark.seal.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Mode Switcher + Tree Controls
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(ExplorerMode.allCases) { mode in
                        Button {
                            explorerMode = mode
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 10))
                                Text(mode.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(explorerMode == mode ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                explorerMode == mode ? CeptraTheme.elevatedBG : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(CeptraTheme.border, lineWidth: 0.75))

                Spacer(minLength: 4)

                if explorerMode == .projectTree {
                    Button {
                        revealActiveFileInTree()
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.activeTabPath == nil)
                    .help("Reveal Active File in Tree")

                    Button {
                        toggleExpandCollapseAll()
                    } label: {
                        Image(systemName: expandedFolders.isEmpty ? "chevron.down.square" : "chevron.up.square")
                            .font(.system(size: 11))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(expandedFolders.isEmpty ? "Expand All Folders" : "Collapse All Folders")

                    Button {
                        showHiddenEntries.toggle()
                    } label: {
                        Image(systemName: showHiddenEntries ? "eye" : "eye.slash")
                            .font(.system(size: 10.5))
                            .foregroundStyle(showHiddenEntries ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(showHiddenEntries ? "Hide Dotfiles" : "Show Dotfiles (.github, .env, etc.)")
                }

                Button {
                    appState.presentNewFolderSheet(inDirectory: appState.activeFileParentRelativeDirectory ?? "")
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(CeptraTheme.border, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .help("New Folder (⌘⇧N)")

                Button {
                    appState.presentNewFileSheet(inDirectory: appState.activeFileParentRelativeDirectory)
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(CeptraTheme.border, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .help("New File (⌘N)")
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 6)

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textMuted)
                TextField("Filter files, folders, scenarios…", text: $appState.sidebarFilterText)
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
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

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

            // Tree Body
            ScrollView {
                if let ws = appState.workspace {
                    switch explorerMode {
                    case .projectTree:
                        projectTreeBody(workspace: ws)
                    case .testSuites:
                        suitesExplorerBody(workspace: ws)
                    }
                }
            }

            Divider().overlay(CeptraTheme.border)

            // Minimalist Workspace Footer
            if let ws = appState.workspace {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ws.totalFeatureCount) suites · \(ws.totalScenarioCount) scenarios · \(ws.files.count) files")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .lineLimit(1)
                        if let tc = appState.resolvedToolchain {
                            Text("\(ws.packageManager.rawValue) · \(tc.resolutionSource)")
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
            initializeDefaultExpansionIfNeeded()
        }
        .onChange(of: appState.workspace?.rootURL.path) { _, _ in
            initializeDefaultExpansionIfNeeded()
        }
        .onChange(of: appState.activeTabPath) { _, newPath in
            if let newPath {
                expandAncestors(for: newPath)
            }
        }
        .onChange(of: appState.pendingRevealTreePath) { _, newPath in
            if let newPath {
                explorerMode = .projectTree
                expandAncestors(for: newPath)
                appState.pendingRevealTreePath = nil
            }
        }
    }

    // MARK: - Full Project Directory Tree

    @ViewBuilder
    private func projectTreeBody(workspace: CodeceptWorkspace) -> some View {
        let query = appState.sidebarFilterText
        let tag = appState.selectedTagFilter
        let isFiltering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tag != nil

        let visibleRoots: [WorkspaceTreeNode] = workspace.rootTree.compactMap { node in
            if !showHiddenEntries && node.isHidden && !isFiltering {
                return nil
            }
            return node.filtered(query: query, tag: tag)
        }

        LazyVStack(alignment: .leading, spacing: 1) {
            // Project root header row
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.accent)
                Text(workspace.rootURL.lastPathComponent.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .tracking(0.6)
                    .lineLimit(1)
                Spacer()
                if let tag {
                    Button {
                        appState.run(mode: .runTag(tag: tag))
                    } label: {
                        Label("Run \(tag)", systemImage: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CeptraTheme.success)
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isRunning)
                } else {
                    Button {
                        appState.presentNewFileSheet(inDirectory: "")
                    } label: {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 10))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("New File in Project Root")

                    Button {
                        appState.presentNewFolderSheet(inDirectory: "")
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 10))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("New Folder in Project Root")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .contextMenu {
                Button("New File in Project Root…") {
                    appState.presentNewFileSheet(inDirectory: "")
                }
                Button("New Folder in Project Root…") {
                    appState.presentNewFolderSheet(inDirectory: "")
                }
                Divider()
                Button("Reveal Project Root in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([workspace.rootURL])
                }
            }

            if visibleRoots.isEmpty {
                Text("No matching files or folders")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(visibleRoots) { node in
                    ProjectTreeNodeView(
                        node: node,
                        depth: 0,
                        forceExpand: isFiltering,
                        showHiddenEntries: showHiddenEntries,
                        expandedFolders: $expandedFolders,
                        expandedTestFiles: $expandedTestFiles
                    )
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    // MARK: - Focused Suites Explorer

    @ViewBuilder
    private func suitesExplorerBody(workspace: CodeceptWorkspace) -> some View {
        let matchingTests = workspace.testFiles.filter { fileMatchesFilters($0) }
        let grouped = Dictionary(grouping: matchingTests) { file -> String in
            let dir = (file.relativePath as NSString).deletingLastPathComponent
            return dir.isEmpty ? "." : dir
        }
        let sortedFolders = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        LazyVStack(alignment: .leading, spacing: 10) {
            if let tag = appState.selectedTagFilter {
                HStack {
                    Text("Filtered by \(tag)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.violet)
                    Spacer()
                    Button {
                        appState.run(mode: .runTag(tag: tag))
                    } label: {
                        Label("Run \(tag)", systemImage: "play.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(CeptraTheme.success)
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isRunning)
                }
                .padding(.horizontal, 8)
            }

            if matchingTests.isEmpty {
                VStack(spacing: 6) {
                    Text("No executable CodeceptJS tests found")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Text("Test files must declare Feature() or Scenario() (or Gherkin Feature:).")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(18)
            } else {
                ForEach(sortedFolders, id: \.self) { folder in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                                .foregroundStyle(CeptraTheme.textMuted)
                            Text(folder == "." ? workspace.rootURL.lastPathComponent : folder)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textMuted)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)

                        ForEach(grouped[folder] ?? []) { file in
                            SuiteFileTreeRow(
                                file: file,
                                depth: 0,
                                forceExpand: !appState.sidebarFilterText.isEmpty || appState.selectedTagFilter != nil,
                                expandedTestFiles: $expandedTestFiles
                            )
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }

    // MARK: - Expansion Helpers

    private func initializeDefaultExpansionIfNeeded() {
        guard let ws = appState.workspace else { return }
        let rootPath = ws.rootURL.path
        guard lastInitializedRootPath != rootPath else { return }
        lastInitializedRootPath = rootPath

        var initialFolders = Set<String>()
        // Expand top-level directories that hold source/tests/pages/helpers (keep output/ & dotfiles collapsed)
        for node in ws.rootTree where node.isDirectory {
            let lower = node.name.lowercased()
            let isGenerated = lower == "output" || lower == "_output"
            if !node.isHidden && !isGenerated && (node.testFileCount > 0 || ["src", "tests", "test", "e2e", "features", "pages"].contains(lower)) {
                initialFolders.insert(node.path)
            }
        }
        expandedFolders = initialFolders

        if let active = appState.activeTabPath {
            expandAncestors(for: active)
        }
        if let firstTest = ws.testFiles.first {
            expandedTestFiles = [firstTest.path]
        } else {
            expandedTestFiles = []
        }
    }

    private func expandAncestors(for filePath: String) {
        guard let ws = appState.workspace else { return }
        for node in ws.rootTree {
            if let ancestors = node.ancestorDirectoryPaths(containing: filePath) {
                for dirPath in ancestors {
                    expandedFolders.insert(dirPath)
                }
                break
            }
        }
    }

    private func revealActiveFileInTree() {
        guard let active = appState.activeTabPath else { return }
        explorerMode = .projectTree
        expandAncestors(for: active)
    }

    private func toggleExpandCollapseAll() {
        guard let ws = appState.workspace else { return }
        if expandedFolders.isEmpty {
            var all = Set<String>()
            for node in ws.rootTree {
                let lower = node.name.lowercased()
                if lower == "output" || lower == "_output" { continue }
                if !showHiddenEntries && node.isHidden { continue }
                all.formUnion(node.allDirectoryPaths())
            }
            expandedFolders = all
        } else {
            expandedFolders.removeAll()
        }
    }

    private func fileMatchesFilters(_ file: WorkspaceFile) -> Bool {
        if let tag = appState.selectedTagFilter, !file.allTags.contains(tag) {
            return false
        }
        let query = appState.sidebarFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return true }
        if file.relativePath.lowercased().contains(query) { return true }
        return file.features.contains { f in
            f.title.lowercased().contains(query) || f.scenarios.contains { $0.title.lowercased().contains(query) }
        }
    }
}

// MARK: - Recursive Tree Node View

private struct ProjectTreeNodeView: View {
    @EnvironmentObject var appState: AppState
    let node: WorkspaceTreeNode
    let depth: Int
    let forceExpand: Bool
    let showHiddenEntries: Bool
    @Binding var expandedFolders: Set<String>
    @Binding var expandedTestFiles: Set<String>

    private var isFolderExpanded: Bool {
        forceExpand || expandedFolders.contains(node.path)
    }

    var body: some View {
        if node.isDirectory {
            folderView
        } else if let file = node.file {
            if file.isExecutableTestFile {
                SuiteFileTreeRow(
                    file: file,
                    depth: depth,
                    forceExpand: forceExpand,
                    expandedTestFiles: $expandedTestFiles
                )
            } else {
                regularFileRow(file: file)
            }
        }
    }

    private var folderView: some View {
        let visibleChildren = node.children.filter { showHiddenEntries || !$0.isHidden || forceExpand }
        return VStack(alignment: .leading, spacing: 1) {
            Button {
                if expandedFolders.contains(node.path) {
                    expandedFolders.remove(node.path)
                } else {
                    expandedFolders.insert(node.path)
                }
            } label: {
                HStack(spacing: 5) {
                    TreeIndentGuides(depth: depth)

                    Image(systemName: isFolderExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .frame(width: 11)

                    Image(systemName: isFolderExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(folderColor(for: node.name, isHidden: node.isHidden))

                    Text(node.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(node.isHidden || isOutputFolder(node.name) ? CeptraTheme.textMuted : CeptraTheme.textPrimary.opacity(0.9))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if node.testFileCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(CeptraTheme.accent.opacity(0.85))
                            Text("\(node.testFileCount)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(CeptraTheme.elevatedBG.opacity(0.75), in: Capsule())
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("New File in \"\(node.name)\"…") {
                    appState.presentNewFileSheet(inDirectory: node.relativePath)
                }
                Button("New Folder in \"\(node.name)\"…") {
                    appState.presentNewFolderSheet(inDirectory: node.relativePath)
                }
                Divider()
                Button("Expand Subtree") {
                    for p in node.allDirectoryPaths() { expandedFolders.insert(p) }
                }
                Button("Collapse Subtree") {
                    for p in node.allDirectoryPaths() { expandedFolders.remove(p) }
                }
                Divider()
                Button("Copy Relative Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.relativePath, forType: .string)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
            }

            if isFolderExpanded {
                ForEach(visibleChildren) { child in
                    ProjectTreeNodeView(
                        node: child,
                        depth: depth + 1,
                        forceExpand: forceExpand,
                        showHiddenEntries: showHiddenEntries,
                        expandedFolders: $expandedFolders,
                        expandedTestFiles: $expandedTestFiles
                    )
                }
            }
        }
    }

    private func regularFileRow(file: WorkspaceFile) -> some View {
        let isActive = appState.activeTabPath == file.path
        let isActiveConfig = appState.workspace?.config.configFilePath == file.path

        return Button {
            appState.openFile(file)
        } label: {
            HStack(spacing: 5) {
                TreeIndentGuides(depth: depth)
                Color.clear.frame(width: 11, height: 1) // align with chevron column

                Image(systemName: iconForFile(file, isActiveConfig: isActiveConfig))
                    .font(.system(size: 11))
                    .foregroundStyle(colorForFile(file, isActiveConfig: isActiveConfig))

                Text(file.name)
                    .font(.system(size: 11.5, weight: isActive || isActiveConfig ? .semibold : .regular))
                    .foregroundStyle(
                        isActive ? CeptraTheme.textPrimary :
                        (node.isHidden ? CeptraTheme.textMuted : CeptraTheme.textSecondary)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if isActiveConfig {
                    Text("ACTIVE")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.accentWarm)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(CeptraTheme.accentWarm.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isActive ? CeptraTheme.elevatedBG : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.relativePath)
        .contextMenu {
            let parentDir = parentRelativeDirectory(for: file.relativePath)
            Button("New File in Same Folder…") {
                appState.presentNewFileSheet(inDirectory: parentDir)
            }
            Button("New Folder in Same Folder…") {
                appState.presentNewFolderSheet(inDirectory: parentDir)
            }
            Divider()
            if ConfigParser.supportedConfigExtensions.contains(file.fileExtension.lowercased()) {
                Button("Use as Active CodeceptJS Config") {
                    appState.setCustomConfigFile(path: file.path)
                }
                Divider()
            }
            Button("Copy Relative Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.relativePath, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
        }
    }

    private func parentRelativeDirectory(for relativePath: String) -> String {
        guard !relativePath.hasPrefix("/") else { return "" }
        let dir = (relativePath as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    private func isOutputFolder(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "output" || lower == "_output"
    }

    private func folderColor(for name: String, isHidden: Bool) -> Color {
        if isHidden || isOutputFolder(name) { return CeptraTheme.textMuted }
        switch name.lowercased() {
        case "tests", "test", "e2e", "specs", "src": return CeptraTheme.accent
        case "features": return CeptraTheme.violet
        case "pages", "fragments", "stepobjects", "step_definitions": return CeptraTheme.cyan
        case "helpers", "configs", "config": return CeptraTheme.accentWarm
        default: return CeptraTheme.textSecondary
        }
    }

    private func iconForFile(_ file: WorkspaceFile, isActiveConfig: Bool) -> String {
        if isActiveConfig { return "gearshape.fill" }
        if file.isBinaryFile { return "photo" }
        switch file.category {
        case .config: return "gearshape"
        case .helper: return "wrench.and.screwdriver"
        case .pageObject: return "rectangle.stack"
        case .stepDefinition: return "list.bullet.indent"
        default:
            switch file.fileExtension.lowercased() {
            case "json": return "curlybraces"
            case "md", "markdown": return "doc.richtext"
            case "yml", "yaml": return "list.bullet.rectangle"
            case "sh", "bash", "zsh": return "terminal"
            case "xml", "html": return "chevron.left.forwardslash.chevron.right"
            default: return "doc.plaintext"
            }
        }
    }

    private func colorForFile(_ file: WorkspaceFile, isActiveConfig: Bool) -> Color {
        if isActiveConfig { return CeptraTheme.accentWarm }
        switch file.category {
        case .config: return CeptraTheme.accentWarm.opacity(0.8)
        case .helper: return CeptraTheme.cyan.opacity(0.85)
        case .pageObject, .stepDefinition: return CeptraTheme.accent.opacity(0.8)
        default: return CeptraTheme.textMuted
        }
    }
}

// MARK: - Executable Test Suite Row (with Expandable Scenarios + Play Button)

private struct SuiteFileTreeRow: View {
    @EnvironmentObject var appState: AppState
    let file: WorkspaceFile
    let depth: Int
    let forceExpand: Bool
    @Binding var expandedTestFiles: Set<String>

    var body: some View {
        let isExpanded = forceExpand || expandedTestFiles.contains(file.path)
        let isActive = appState.activeTabPath == file.path
        let allScenarios = file.features.flatMap(\.scenarios)
        let matchingScenarios = allScenarios.filter { scenarioMatchesFilters($0) }

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                TreeIndentGuides(depth: depth)

                Button {
                    if expandedTestFiles.contains(file.path) {
                        expandedTestFiles.remove(file.path)
                    } else {
                        expandedTestFiles.insert(file.path)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .frame(width: 11)
                }
                .buttonStyle(.plain)

                Button {
                    appState.openFile(file)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: file.category.symbolName)
                            .font(.system(size: 11))
                            .foregroundStyle(file.category == .gherkinFeature ? CeptraTheme.violet : CeptraTheme.success)

                        Text(file.name)
                            .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                            .foregroundStyle(isActive ? CeptraTheme.textPrimary : CeptraTheme.textPrimary.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("\(matchingScenarios.count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(CeptraTheme.elevatedBG, in: Capsule())

                Button {
                    appState.run(mode: .runFile(relativePath: file.relativePath))
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(CeptraTheme.success)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(appState.isRunning)
                .help("Run \(file.name)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isActive ? CeptraTheme.elevatedBG : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contextMenu {
                Button("Run Test File") {
                    appState.run(mode: .runFile(relativePath: file.relativePath))
                }
                .disabled(appState.isRunning)
                Divider()
                let parentDir: String = {
                    guard !file.relativePath.hasPrefix("/") else { return "" }
                    let dir = (file.relativePath as NSString).deletingLastPathComponent
                    return dir == "." ? "" : dir
                }()
                Button("New File in Same Folder…") {
                    appState.presentNewFileSheet(inDirectory: parentDir)
                }
                Button("New Folder in Same Folder…") {
                    appState.presentNewFolderSheet(inDirectory: parentDir)
                }
                Divider()
                Button("Copy Relative Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.relativePath, forType: .string)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
            }

            if isExpanded {
                ForEach(matchingScenarios) { scenario in
                    let status = appState.statusForScenario(scenario)
                    HStack(spacing: 5) {
                        TreeIndentGuides(depth: depth + 1)
                        Color.clear.frame(width: 8, height: 1)
                        StatusDotView(status: status, size: 6.5)

                        Button {
                            appState.openFile(file, jumpToLine: scenario.lineNumber)
                        } label: {
                            HStack(spacing: 4) {
                                Text(scenario.cleanTitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(scenario.modifier == .skip ? CeptraTheme.textMuted : CeptraTheme.textSecondary)
                                    .strikethrough(scenario.modifier == .skip)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if let ms = appState.durationForScenario(scenario) {
                            Text(ReportExporter.formatDuration(ms: ms))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }

                        Button {
                            appState.run(mode: .runScenario(relativePath: file.relativePath, scenarioTitle: scenario.cleanTitle))
                        } label: {
                            Image(systemName: "play")
                                .font(.system(size: 8.5))
                                .foregroundStyle(CeptraTheme.textSecondary)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isRunning)
                        .help("Run scenario \"\(scenario.cleanTitle)\"")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
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

private struct TreeIndentGuides: View {
    let depth: Int

    var body: some View {
        if depth > 0 {
            HStack(spacing: 0) {
                ForEach(0..<depth, id: \.self) { _ in
                    HStack(spacing: 0) {
                        Spacer().frame(width: 5)
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 1)
                        Spacer().frame(width: 7)
                    }
                    .frame(width: 13)
                }
            }
        }
    }
}
