import AppKit
import CeptraCore
import SwiftUI

struct SidebarExplorerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var explorerMode: ExplorerMode = .suites
    @State private var expandedFolders: Set<String> = []
    @State private var expandedTestFiles: Set<String> = []
    @State private var showHiddenEntries: Bool = true
    @State private var lastInitializedRootPath: String = ""
    @State private var hoveredTag: String?
    @State private var isSearchHovered = false
    @State private var isPlusHovered = false

    enum ExplorerMode: String, CaseIterable, Identifiable {
        case suites = "Suites"
        case files = "Files"
        case pages = "Pages"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Plain-text 38pt Suites · Files · Pages header + (+) New Menu
            HStack(spacing: 12) {
                HStack(spacing: 14) {
                    ForEach(ExplorerMode.allCases) { mode in
                        let isSelected = explorerMode == mode
                        Button {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                                explorerMode = mode
                            }
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textSecondary.opacity(0.85))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 4)

                Menu {
                    Button("New File… (⌘N)") {
                        appState.presentNewFileSheet(inDirectory: appState.activeFileParentRelativeDirectory)
                    }
                    Button("New Folder… (⌘⇧N)") {
                        appState.presentNewFolderSheet(inDirectory: appState.activeFileParentRelativeDirectory ?? "")
                    }
                    Divider()
                    Button("Rescan Workspace") {
                        appState.rescanWorkspace()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isPlusHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            isPlusHovered ? CeptraTheme.hoverBG : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isPlusHovered ? CeptraTheme.border : Color.clear, lineWidth: 0.75)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 26)
                .onHover { isPlusHovered = $0 }
                .help("New File, New Folder, or Rescan")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }

            // Compact Filter… ⌘P bar
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isSearchHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                TextField("Filter…", text: $appState.sidebarFilterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(CeptraTheme.textPrimary)
                if !appState.sidebarFilterText.isEmpty {
                    Button {
                        withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                            appState.sidebarFilterText = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(CeptraTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                } else {
                    Button {
                        appState.showingCommandPalette = true
                    } label: {
                        Text("⌘P")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Quick Open File (⌘P)")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 7.5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .strokeBorder(isSearchHovered ? CeptraTheme.borderStrong : CeptraTheme.border, lineWidth: 1)
            )
            .onHover { hovering in
                isSearchHovered = hovering
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }

            // Tag filter strip (only when tags exist)
            if let tags = appState.workspace?.allTags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            let selected = appState.selectedTagFilter == tag
                            let isHovered = hoveredTag == tag
                            Button {
                                withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                                    appState.selectedTagFilter = selected ? nil : tag
                                }
                            } label: {
                                Text(tag)
                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(selected ? .white : CeptraTheme.violet)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        selected
                                            ? CeptraTheme.violet
                                            : CeptraTheme.violet.opacity(isHovered ? 0.22 : 0.14),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                hoveredTag = hovering ? tag : (hoveredTag == tag ? nil : hoveredTag)
                            }
                            .contextMenu {
                                Button("Run tests with \(tag)") {
                                    appState.run(mode: .runTag(tag: tag))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CeptraTheme.border).frame(height: 1)
                }
            }

            // Clean Full-Height Tree Body (extends to soft rounded bottom edge with zero redundant footer)
            ScrollView {
                if let ws = appState.workspace {
                    switch explorerMode {
                    case .suites:
                        suitesExplorerBody(workspace: ws)
                    case .files:
                        projectTreeBody(workspace: ws)
                    case .pages:
                        pagesExplorerBody(workspace: ws)
                    }
                }
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
                explorerMode = .files
                expandAncestors(for: newPath)
                appState.pendingRevealTreePath = nil
            }
        }
    }

    // MARK: - Pages & Helpers Explorer

    @ViewBuilder
    private func pagesExplorerBody(workspace: CodeceptWorkspace) -> some View {
        let query = appState.sidebarFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pageObjects = workspace.files.filter { file in
            let isPageLike = file.category == .pageObject || file.category == .stepDefinition || file.category == .helper
            guard isPageLike else { return false }
            if query.isEmpty { return true }
            return file.name.lowercased().contains(query) || file.relativePath.lowercased().contains(query)
        }

        LazyVStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("PAGE OBJECTS & HELPERS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(CeptraTheme.textMuted)
                Spacer()
                Text("\(pageObjects.count)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(CeptraTheme.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if pageObjects.isEmpty {
                Text("No page objects or helpers found")
                    .font(.system(size: 12.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(pageObjects) { file in
                    let isActive = appState.activeTabPath == file.path
                    let badge: (String, Color) = {
                        switch file.category {
                        case .pageObject: return ("PO", CeptraTheme.violet)
                        case .stepDefinition: return ("STP", CeptraTheme.accent)
                        default: return ("HLP", CeptraTheme.cyan)
                        }
                    }()
                    Button {
                        appState.openFile(file)
                    } label: {
                        HStack(spacing: 8) {
                            Text(badge.0)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(badge.1)
                                .frame(width: 28, alignment: .leading)
                            Text(file.name)
                                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                                .foregroundStyle(isActive ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isActive ? CeptraTheme.activeBG : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(file.relativePath)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
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
                    .font(.system(size: 13))
                    .foregroundStyle(CeptraTheme.accent)
                Text(workspace.rootURL.lastPathComponent.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .tracking(0.6)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let tag {
                    Button {
                        appState.run(mode: .runTag(tag: tag))
                    } label: {
                        Label("Run \(tag)", systemImage: "play.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(CeptraTheme.success)
                    }
                    .buttonStyle(CeptraTactilePressStyle())
                    .disabled(appState.isRunning)
                } else {
                    HStack(spacing: 3) {
                        Button {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                                revealActiveFileInTree()
                            }
                        } label: {
                            Image(systemName: "scope")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(appState.activeTabPath == nil ? CeptraTheme.textMuted.opacity(0.45) : CeptraTheme.textSecondary)
                                .frame(width: 24, height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.92))
                        .disabled(appState.activeTabPath == nil)
                        .help("Reveal Active File in Tree")

                        Button {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                                toggleExpandCollapseAll()
                            }
                        } label: {
                            Image(systemName: expandedFolders.isEmpty ? "chevron.down.square" : "chevron.up.square")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(CeptraTheme.textSecondary)
                                .frame(width: 24, height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.92))
                        .help(expandedFolders.isEmpty ? "Expand All Folders" : "Collapse All Folders")

                        Button {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                                showHiddenEntries.toggle()
                            }
                        } label: {
                            Image(systemName: showHiddenEntries ? "eye" : "eye.slash")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(showHiddenEntries ? CeptraTheme.textSecondary : CeptraTheme.textMuted.opacity(0.7))
                                .frame(width: 24, height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.92))
                        .help(showHiddenEntries ? "Hide Dotfiles" : "Show Dotfiles (.github, .env, etc.)")
                    }
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
                    .font(.system(size: 12.5))
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

        LazyVStack(alignment: .leading, spacing: 11) {
            if let tag = appState.selectedTagFilter {
                HStack {
                    Text("Filtered by \(tag)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CeptraTheme.violet)
                    Spacer()
                    Button {
                        appState.run(mode: .runTag(tag: tag))
                    } label: {
                        Label("Run \(tag)", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Text("Test files must declare Feature() or Scenario() (or Gherkin Feature:).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(18)
            } else {
                ForEach(sortedFolders, id: \.self) { folder in
                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(CeptraTheme.textSecondary)
                            Text(folder == "." ? workspace.rootURL.lastPathComponent : folder)
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)

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
        explorerMode = .files
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let node: WorkspaceTreeNode
    let depth: Int
    let forceExpand: Bool
    let showHiddenEntries: Bool
    @Binding var expandedFolders: Set<String>
    @Binding var expandedTestFiles: Set<String>
    @State private var isHovered = false

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
                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                    if expandedFolders.contains(node.path) {
                        expandedFolders.remove(node.path)
                    } else {
                        expandedFolders.insert(node.path)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    TreeIndentGuides(depth: depth)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                        .rotationEffect(.degrees(isFolderExpanded ? 90 : 0))
                        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: isFolderExpanded)
                        .frame(width: 13)

                    Image(systemName: isFolderExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 13.5))
                        .foregroundStyle(folderColor(for: node.name, isHidden: node.isHidden))

                    Text(node.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            node.isHidden || isOutputFolder(node.name)
                                ? CeptraTheme.textMuted
                                : (isHovered ? CeptraTheme.textPrimary : CeptraTheme.textPrimary.opacity(0.92))
                        )
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if node.testFileCount > 0 {
                        HStack(spacing: 3.5) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(CeptraTheme.accent.opacity(0.9))
                            Text("\(node.testFileCount)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textSecondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(CeptraTheme.elevatedBG.opacity(0.75), in: Capsule())
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background {
                    if isHovered {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(CeptraTheme.glassHoverOverlay)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
                            )
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            .contextMenu {
                Button("New File in \"\(node.name)\"…") {
                    appState.presentNewFileSheet(inDirectory: node.relativePath)
                }
                Button("New Folder in \"\(node.name)\"…") {
                    appState.presentNewFolderSheet(inDirectory: node.relativePath)
                }
                Divider()
                Button("Expand Subtree") {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                        for p in node.allDirectoryPaths() { expandedFolders.insert(p) }
                    }
                }
                Button("Collapse Subtree") {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                        for p in node.allDirectoryPaths() { expandedFolders.remove(p) }
                    }
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
                VStack(alignment: .leading, spacing: 1) {
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
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func regularFileRow(file: WorkspaceFile) -> some View {
        let isActive = appState.activeTabPath == file.path
        let isActiveConfig = appState.workspace?.config.configFilePath == file.path

        return Button {
            appState.openFile(file)
        } label: {
            HStack(spacing: 6) {
                TreeIndentGuides(depth: depth)
                Color.clear.frame(width: 13, height: 1) // align with chevron column

                Image(systemName: iconForFile(file, isActiveConfig: isActiveConfig))
                    .font(.system(size: 13.5))
                    .foregroundStyle(colorForFile(file, isActiveConfig: isActiveConfig))

                Text(file.name)
                    .font(.system(size: 13, weight: isActive || isActiveConfig ? .semibold : .regular))
                    .foregroundStyle(
                        isActive || isHovered ? CeptraTheme.textPrimary :
                        (node.isHidden ? CeptraTheme.textMuted : CeptraTheme.textSecondary)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if isActiveConfig {
                    Text("ACTIVE")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.accentWarm)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CeptraTheme.accentWarm.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                let rowShape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                if isActive {
                    rowShape
                        .fill(CeptraTheme.elevatedBG.opacity(0.88))
                        .overlay(rowShape.strokeBorder(CeptraTheme.specularRimGradient, lineWidth: 0.7))
                } else if isHovered {
                    rowShape
                        .fill(CeptraTheme.glassHoverOverlay)
                        .overlay(rowShape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
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
            if ["json", "http", "rest", "env"].contains(file.fileExtension.lowercased()) || file.name.lowercased().hasPrefix(".env") {
                Button("Import into API Studio") {
                    appState.importAPIFiles(urls: [file.url])
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let file: WorkspaceFile
    let depth: Int
    let forceExpand: Bool
    @Binding var expandedTestFiles: Set<String>

    @State private var isRowHovered = false
    @State private var hoveredScenarioID: ParsedScenario.ID?

    var body: some View {
        let isExpanded = forceExpand || expandedTestFiles.contains(file.path)
        let isActive = appState.activeTabPath == file.path
        let allScenarios = file.features.flatMap(\.scenarios)
        let matchingScenarios = allScenarios.filter { scenarioMatchesFilters($0) }

        VStack(alignment: .leading, spacing: 1.5) {
            HStack(spacing: 6) {
                TreeIndentGuides(depth: depth)

                Button {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                        if expandedTestFiles.contains(file.path) {
                            expandedTestFiles.remove(file.path)
                        } else {
                            expandedTestFiles.insert(file.path)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isRowHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: isExpanded)
                        .frame(width: 16, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse Scenarios" : "Expand Scenarios")
                .accessibilityLabel(isExpanded ? "Collapse \(file.name)" : "Expand \(file.name)")

                Button {
                    appState.openFile(file)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: file.category.symbolName)
                            .font(.system(size: 13.5))
                            .foregroundStyle(file.category == .gherkinFeature ? CeptraTheme.violet : CeptraTheme.success)

                        Text(file.name)
                            .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                            .foregroundStyle(isActive || isRowHovered ? CeptraTheme.textPrimary : CeptraTheme.textPrimary.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isRowHovered {
                    Button {
                        appState.run(mode: .runFile(relativePath: file.relativePath))
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(CeptraTheme.success)
                            .frame(width: 22, height: 22)
                            .background(CeptraTheme.success.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(CeptraTactilePressStyle())
                    .disabled(appState.isRunning)
                    .help("Run \(file.name)")
                } else {
                    Text("\(matchingScenarios.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .padding(.trailing, 3)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5.5)
            .background {
                let rowShape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                if isActive {
                    rowShape
                        .fill(CeptraTheme.elevatedBG.opacity(0.88))
                        .overlay(rowShape.strokeBorder(CeptraTheme.specularRimGradient, lineWidth: 0.7))
                } else if isRowHovered {
                    rowShape
                        .fill(CeptraTheme.glassHoverOverlay)
                        .overlay(rowShape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isRowHovered)
            .onHover { hovering in
                isRowHovered = hovering
            }
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
                VStack(alignment: .leading, spacing: 1.5) {
                    ForEach(matchingScenarios) { scenario in
                        let status = appState.statusForScenario(scenario)
                        let isScenarioHovered = hoveredScenarioID == scenario.id
                        HStack(spacing: 6) {
                            TreeIndentGuides(depth: depth + 1)
                            Color.clear.frame(width: 8, height: 1)
                            StatusDotView(status: status, size: 8)

                            Button {
                                appState.openFile(file, jumpToLine: scenario.lineNumber)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(scenario.cleanTitle)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(
                                            scenario.modifier == .skip
                                                ? CeptraTheme.textMuted
                                                : (isScenarioHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                                        )
                                        .strikethrough(scenario.modifier == .skip)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if isScenarioHovered {
                                Button {
                                    appState.run(mode: .runScenario(relativePath: file.relativePath, scenarioTitle: scenario.cleanTitle))
                                } label: {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(CeptraTheme.success)
                                        .frame(width: 22, height: 22)
                                        .background(CeptraTheme.success.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(CeptraTactilePressStyle())
                                .disabled(appState.isRunning)
                                .help("Run scenario \"\(scenario.cleanTitle)\"")
                            } else if let ms = appState.durationForScenario(scenario) {
                                Text(ReportExporter.formatDuration(ms: ms))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(status == .failed ? CeptraTheme.failure : CeptraTheme.textMuted)
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4.5)
                        .background {
                            if isScenarioHovered {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(CeptraTheme.glassHoverOverlay)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6)
                                    )
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isScenarioHovered)
                        .onHover { hovering in
                            hoveredScenarioID = hovering ? scenario.id : (hoveredScenarioID == scenario.id ? nil : hoveredScenarioID)
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
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
