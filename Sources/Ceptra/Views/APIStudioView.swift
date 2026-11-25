import AppKit
import CeptraCore
import SwiftUI

struct APIStudioView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchText: String = ""
    @State private var expandedCollectionIDs: Set<UUID> = []
    @State private var expandedFolderIDs: Set<UUID> = []

    @State private var activeRequestTab: RequestEditorTab = .params
    @State private var activeResponseTab: ResponseViewerTab = .body
    @State private var showCollectionRunnerPane: Bool = false
    @State private var prettyPrintResponse: Bool = true
    @State private var responseSearchQuery: String = ""
    @State private var selectedSnippetLang: APICodeSnippetLanguage = .curl

    @State private var showingEnvironmentSheet: Bool = false
    @State private var showingImportCurlSheet: Bool = false
    @State private var renameTarget: RenameTarget? = nil
    @State private var renameDraft: String = ""

    @State private var sidebarWidth: CGFloat = 248
    @State private var sidebarDragStart: CGFloat = 248
    @State private var responseHeight: CGFloat = 260
    @State private var responseDragStart: CGFloat = 260

    enum RequestEditorTab: String, CaseIterable, Identifiable {
        case params = "Params"
        case auth = "Auth"
        case headers = "Headers"
        case body = "Body"
        case assertions = "Assertions"
        case extractors = "Extract Vars"
        case scripts = "Scripts"
        var id: String { rawValue }
    }

    enum ResponseViewerTab: String, CaseIterable, Identifiable {
        case body = "Body"
        case headers = "Headers"
        case cookies = "Cookies"
        case assertions = "Assertions"
        case code = "Code"
        case history = "History"
        var id: String { rawValue }
    }

    enum RenameTarget: Identifiable {
        case collection(UUID, String)
        case folder(UUID, UUID, String)
        case request(UUID, String)

        var id: String {
            switch self {
            case .collection(let id, _): return "col-\(id)"
            case .folder(_, let id, _): return "fld-\(id)"
            case .request(let id, _): return "req-\(id)"
            }
        }

        var currentName: String {
            switch self {
            case .collection(_, let n), .folder(_, _, let n), .request(_, let n): return n
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            apiTopToolbar

            GeometryReader { geo in
                let minSide: CGFloat = 200
                let maxSide = max(minSide, min(360, geo.size.width * 0.36))
                let effSide = min(max(sidebarWidth, minSide), maxSide)

                HStack(spacing: 0) {
                    collectionsSidebar
                        .frame(width: effSide)

                    CeptraSplitResizeHandle(
                        axis: .horizontal,
                        cursorDirection: .both,
                        onDragStart: { sidebarDragStart = effSide },
                        onDragChanged: { delta in
                            sidebarWidth = min(max(sidebarDragStart + delta, minSide), maxSide)
                        },
                        onDragEnd: {},
                        onDoubleClick: { sidebarWidth = 248 }
                    )

                    if let ctx = appState.selectedAPIRequestContext {
                        requestAndResponseStage(collection: ctx.collection, request: ctx.request, effectiveAuth: ctx.effectiveAuth)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        emptyWorkspaceStage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(CeptraTheme.canvasBG)
        .onAppear {
            appState.ensureAPIStudioLoaded()
            syncDefaultExpansion()
            selectedSnippetLang = defaultSnippetLanguageForFramework()
        }
        .onChange(of: appState.apiCollections.map(\.id)) { _, _ in
            syncDefaultExpansion()
        }
        .onChange(of: appState.apiCollectionRunSummary?.id) { _, newID in
            if newID != nil {
                showCollectionRunnerPane = true
            }
        }
        .sheet(isPresented: $showingEnvironmentSheet) {
            APIEnvironmentManagerSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingImportCurlSheet) {
            APIImportCurlSheet()
                .environmentObject(appState)
        }
        .sheet(item: $renameTarget) { target in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(target) }
                HStack {
                    Spacer()
                    Button("Cancel") { renameTarget = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Rename") { commitRename(target) }
                        .buttonStyle(.borderedProminent)
                        .tint(CeptraTheme.accent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(18)
            .frame(width: 340)
            .background(CeptraTheme.panelBG)
        }
    }

    private func defaultSnippetLanguageForFramework() -> APICodeSnippetLanguage {
        switch appState.activeFramework {
        case .codeceptJS: return .codeceptJS
        case .playwright: return .playwrightTS
        case .playwrightPython: return .playwrightPython
        }
    }

    private func syncDefaultExpansion() {
        for col in appState.apiCollections {
            expandedCollectionIDs.insert(col.id)
            for f in col.folders {
                expandedFolderIDs.insert(f.id)
            }
        }
    }

    private func commitRename(_ target: RenameTarget) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch target {
        case .collection(let id, _):
            appState.renameAPICollection(id: id, newName: trimmed)
        case .folder(let cid, let fid, _):
            appState.renameAPIFolder(collectionID: cid, folderID: fid, newName: trimmed)
        case .request(let rid, _):
            if let ctx = appState.selectedAPIRequestContext, ctx.request.id == rid {
                var copy = ctx.request
                copy.name = trimmed
                appState.updateAPIRequest(copy)
            } else {
                for col in appState.apiCollections {
                    if let found = col.request(withID: rid) {
                        var copy = found.request
                        copy.name = trimmed
                        appState.updateAPIRequest(copy)
                        break
                    }
                }
            }
        }
        renameTarget = nil
    }

    // MARK: - Top 38pt API Studio Toolbar

    private var apiTopToolbar: some View {
        HStack(spacing: 8) {
            // Back to Code Editor pill
            Button {
                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                    appState.isAPIStudioVisible = false
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Code Editor")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(CeptraTheme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(CeptraTheme.hoverBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Return to Code Editor (⌘⌥I)")

            Rectangle().fill(CeptraTheme.border).frame(width: 1, height: 16)

            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CeptraTheme.cyan)
                Text("API Client Studio")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)
            }

            // Import & Examples Menu
            Menu {
                Button("Import File (Postman / Insomnia / OpenAPI / HAR / .http / .env)…") {
                    appState.presentImportAPIFilePanel()
                }
                Button("Import cURL Command…") {
                    showingImportCurlSheet = true
                }
                Divider()
                Button("New Blank Collection") {
                    _ = appState.createAPICollection()
                }
                Menu("Load Example Collection") {
                    ForEach(APIStudioStore.ExampleTemplate.allCases) { tpl in
                        Button(tpl.title) {
                            appState.loadAPIExample(tpl)
                        }
                    }
                    Divider()
                    Button("Load All 3 Examples (REST + Auth + GraphQL)") {
                        appState.loadAllAPIExamples()
                    }
                }
                Button("Generate Sample Import Files (Postman / Insomnia / OpenAPI / .http)…") {
                    appState.generateSampleAPIImportFilesPanel()
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(CeptraTheme.elevatedBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Export Menu
            Menu {
                if let col = appState.selectedAPICollection {
                    Section("Export Collection \"\(col.name)\"") {
                        ForEach(APIExportCollectionFormat.allCases) { fmt in
                            Button(fmt.rawValue) {
                                appState.exportAPICollection(col, format: fmt)
                            }
                        }
                    }
                    Divider()
                    Button("Generate \(appState.activeFramework.displayName) Test Suite File…") {
                        appState.generateAutomatedTestSuiteFile(from: col)
                    }
                } else {
                    Text("Select a collection to export")
                }
                if let env = appState.activeAPIEnvironment {
                    Divider()
                    Section("Export Environment \"\(env.name)\" (Secrets Redacted)") {
                        ForEach(APIExportEnvironmentFormat.allCases) { fmt in
                            Button(fmt.rawValue) {
                                appState.exportAPIEnvironment(env, format: fmt, redactSecrets: true)
                            }
                        }
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(CeptraTheme.hoverBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(appState.apiCollections.isEmpty && appState.apiEnvironments.isEmpty)

            Spacer(minLength: 8)

            // Active Environment Picker + Manager
            HStack(spacing: 4) {
                Menu {
                    Button {
                        appState.apiActiveEnvironmentID = nil
                        appState.saveAPIStudio()
                    } label: {
                        if appState.apiActiveEnvironmentID == nil {
                            Label("No Environment", systemImage: "checkmark")
                        } else {
                            Text("No Environment")
                        }
                    }
                    if !appState.apiEnvironments.isEmpty {
                        Divider()
                        ForEach(appState.apiEnvironments) { env in
                            Button {
                                appState.apiActiveEnvironmentID = env.id
                                appState.saveAPIStudio()
                            } label: {
                                if appState.apiActiveEnvironmentID == env.id {
                                    Label("\(env.name) (\(env.variables.count))", systemImage: "checkmark")
                                } else {
                                    Text("\(env.name) (\(env.variables.count))")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Manage Environments…") {
                        showingEnvironmentSheet = true
                    }
                    Button("Import Environment JSON / .env…") {
                        appState.presentImportAPIFilePanel()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(appState.activeAPIEnvironment != nil ? CeptraTheme.success : CeptraTheme.textMuted)
                            .frame(width: 6, height: 6)
                        Text(appState.activeAPIEnvironment?.name ?? "No Environment")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(CeptraTheme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button {
                    showingEnvironmentSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(CeptraTheme.hoverBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Manage Environments & Variables")
            }

            if let col = appState.selectedAPICollection {
                Button {
                    if appState.isAPIRunning {
                        appState.cancelAPIExecution()
                    } else {
                        showCollectionRunnerPane = true
                        appState.runAPICollection(collectionID: col.id)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: appState.isAPIRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(appState.isAPIRunning ? "Stop" : "Run Collection")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(appState.isAPIRunning ? CeptraTheme.failure : CeptraTheme.success, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Run all \(col.totalRequestCount) requests in \(col.name)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(CeptraTheme.sidebarBG)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CeptraTheme.border).frame(height: 1)
        }
    }

    // MARK: - Left Collections Sidebar

    private var collectionsSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                    TextField("Filter requests…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))

                Menu {
                    Button("New Blank Collection") {
                        _ = appState.createAPICollection()
                    }
                    Divider()
                    Section("Runnable Examples") {
                        ForEach(APIStudioStore.ExampleTemplate.allCases) { tpl in
                            Button(tpl.shortTitle) {
                                appState.loadAPIExample(tpl)
                            }
                        }
                        Button("Load All Examples") {
                            appState.loadAllAPIExamples()
                        }
                    }
                    Divider()
                    Button("Generate Sample Import Files (Postman / Insomnia / OpenAPI)…") {
                        appState.generateSampleAPIImportFilesPanel()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(CeptraTheme.hoverBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 26)
                .help("New Collection or Load Runnable Examples")
            }
            .padding(8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }

            if appState.apiCollections.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(CeptraTheme.textMuted)
                    Text("No Collections Yet")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Text("Import Postman, Insomnia, OpenAPI, HAR, .http, or cURL — or load a live runnable example.")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    VStack(spacing: 6) {
                        Button("Import File…") {
                            appState.presentImportAPIFilePanel()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CeptraTheme.accent)
                        .controlSize(.small)

                        Button("Load All Examples") {
                            appState.loadAllAPIExamples()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Generate Sample Files…") {
                            appState.generateSampleAPIImportFilesPanel()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CeptraTheme.accent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appState.apiCollections) { col in
                            collectionTreeSection(col)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(CeptraTheme.sidebarBG)
    }

    @ViewBuilder
    private func collectionTreeSection(_ col: APICollection) -> some View {
        let isExpanded = expandedCollectionIDs.contains(col.id) || !searchText.isEmpty
        let isSelectedCol = appState.apiSelectedCollectionID == col.id

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .frame(width: 12)
                Image(systemName: "shippingbox")
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelectedCol ? CeptraTheme.cyan : CeptraTheme.textSecondary)
                Text(col.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(col.totalRequestCount)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(isSelectedCol ? CeptraTheme.hoverBG.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                appState.apiSelectedCollectionID = col.id
                if expandedCollectionIDs.contains(col.id) {
                    expandedCollectionIDs.remove(col.id)
                } else {
                    expandedCollectionIDs.insert(col.id)
                }
            }
            .contextMenu {
                Button("New Request") {
                    expandedCollectionIDs.insert(col.id)
                    _ = appState.addAPIRequest(inCollection: col.id)
                }
                Button("New Folder") {
                    expandedCollectionIDs.insert(col.id)
                    appState.addAPIFolder(inCollection: col.id)
                }
                Divider()
                Button("Run Collection") {
                    showCollectionRunnerPane = true
                    appState.runAPICollection(collectionID: col.id)
                }
                Button("Generate \(appState.activeFramework.displayName) Test Suite…") {
                    appState.generateAutomatedTestSuiteFile(from: col)
                }
                Divider()
                Menu("Export Collection") {
                    ForEach(APIExportCollectionFormat.allCases) { fmt in
                        Button(fmt.rawValue) {
                            appState.exportAPICollection(col, format: fmt)
                        }
                    }
                }
                Divider()
                Button("Rename…") {
                    renameDraft = col.name
                    renameTarget = .collection(col.id, col.name)
                }
                Button("Duplicate") {
                    appState.duplicateAPICollection(id: col.id)
                }
                Button("Delete Collection", role: .destructive) {
                    appState.deleteAPICollection(id: col.id)
                }
            }

            if isExpanded {
                ForEach(col.folders) { folder in
                    folderTreeNode(folder, inCollection: col, depth: 1)
                }
                ForEach(filteredRequests(col.requests)) { req in
                    requestTreeRow(req, inCollection: col, depth: 1)
                }
            }
        }
    }

    private func folderTreeNode(_ folder: APIFolder, inCollection col: APICollection, depth: Int) -> AnyView {
        let isExpanded = expandedFolderIDs.contains(folder.id) || !searchText.isEmpty
        return AnyView(
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Color.clear.frame(width: CGFloat(depth * 12), height: 1)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .frame(width: 10)
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.accentWarm)
                    Text(folder.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(folder.totalRequestCount)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    if expandedFolderIDs.contains(folder.id) {
                        expandedFolderIDs.remove(folder.id)
                    } else {
                        expandedFolderIDs.insert(folder.id)
                    }
                }
                .contextMenu {
                    Button("New Request in Folder") {
                        expandedFolderIDs.insert(folder.id)
                        _ = appState.addAPIRequest(inCollection: col.id, folderID: folder.id)
                    }
                    Button("New Subfolder") {
                        expandedFolderIDs.insert(folder.id)
                        appState.addAPIFolder(inCollection: col.id, parentFolderID: folder.id)
                    }
                    Divider()
                    Button("Run Folder") {
                        showCollectionRunnerPane = true
                        appState.runAPICollection(collectionID: col.id, folderID: folder.id)
                    }
                    Divider()
                    Button("Rename…") {
                        renameDraft = folder.name
                        renameTarget = .folder(col.id, folder.id, folder.name)
                    }
                    Button("Delete Folder", role: .destructive) {
                        appState.deleteAPIFolder(collectionID: col.id, folderID: folder.id)
                    }
                }

                if isExpanded {
                    ForEach(folder.folders) { sub in
                        folderTreeNode(sub, inCollection: col, depth: depth + 1)
                    }
                    ForEach(filteredRequests(folder.requests)) { req in
                        requestTreeRow(req, inCollection: col, depth: depth + 1)
                    }
                }
            }
        )
    }

    private func requestTreeRow(_ req: APIRequestItem, inCollection col: APICollection, depth: Int) -> some View {
        let isSelected = appState.apiSelectedRequestID == req.id
        return HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth * 12 + 4), height: 1)
            Text(shortMethodLabel(req.method))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(methodColor(req.method))
                .frame(width: 30, alignment: .leading)
            Text(req.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(isSelected ? CeptraTheme.activeBG : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            showCollectionRunnerPane = false
            appState.selectAPIRequest(id: req.id, inCollection: col.id)
        }
        .contextMenu {
            Button("Send Request") {
                appState.selectAPIRequest(id: req.id, inCollection: col.id)
                showCollectionRunnerPane = false
                appState.sendSelectedAPIRequest()
            }
            Button("Copy as cURL") {
                let auth = col.request(withID: req.id)?.effectiveAuth ?? req.auth
                let vars = APIVariableResolver.mergedVariables(collection: col, environment: appState.activeAPIEnvironment)
                let curl = APICodeGenerator.snippet(for: req, effectiveAuth: auth, variables: vars, language: .curl)
                appState.copyTextToPasteboard(curl, label: "cURL command")
            }
            Divider()
            Button("Rename…") {
                renameDraft = req.name
                renameTarget = .request(req.id, req.name)
            }
            Button("Duplicate") {
                appState.duplicateAPIRequest(id: req.id, inCollection: col.id)
            }
            Button("Delete Request", role: .destructive) {
                appState.deleteAPIRequest(id: req.id, inCollection: col.id)
            }
        }
    }

    private func filteredRequests(_ requests: [APIRequestItem]) -> [APIRequestItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return requests }
        return requests.filter {
            $0.name.lowercased().contains(q)
                || $0.url.lowercased().contains(q)
                || $0.method.rawValue.lowercased().contains(q)
        }
    }

    // MARK: - Main Request & Response Split Workspace

    private func requestAndResponseStage(
        collection: APICollection,
        request: APIRequestItem,
        effectiveAuth: APIAuthConfig
    ) -> some View {
        let mergedVars = APIVariableResolver.mergedVariables(collection: collection, environment: appState.activeAPIEnvironment)
        let resolvedURL = APIVariableResolver.resolve(
            APIFormatCodec.composeRawURL(baseURL: request.url, queryParams: request.queryParams),
            variables: mergedVars
        )
        let missingVars = APIVariableResolver.unresolvedVariableNames(in: request.url, variables: mergedVars)

        return GeometryReader { geo in
            let minResp: CGFloat = 170
            let maxResp = max(minResp, geo.size.height - 190)
            let effResp = min(max(responseHeight, minResp), maxResp)

            VStack(spacing: 0) {
                // Request Title + URL Bar + Send
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(
                            "Request Name",
                            text: Binding(
                                get: { request.name },
                                set: { var r = request; r.name = $0; appState.updateAPIRequest(r) }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)

                        Spacer(minLength: 8)

                        Text(collection.sourceFormat.displayName)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(CeptraTheme.hoverBG, in: Capsule())
                    }

                    HStack(spacing: 6) {
                        Picker(
                            "",
                            selection: Binding(
                                get: { request.method },
                                set: { var r = request; r.method = $0; appState.updateAPIRequest(r) }
                            )
                        ) {
                            ForEach(APIHTTPMethod.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 96)

                        TextField(
                            "https://api.example.com/v1/resource or {{baseUrl}}/endpoint",
                            text: Binding(
                                get: { request.url },
                                set: { var r = request; r.url = $0; appState.updateAPIRequest(r) }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(missingVars.isEmpty ? CeptraTheme.borderStrong : CeptraTheme.warning.opacity(0.7), lineWidth: 1)
                        )
                        .onSubmit {
                            showCollectionRunnerPane = false
                            appState.sendSelectedAPIRequest()
                        }

                        Button {
                            if appState.isAPIRunning {
                                appState.cancelAPIExecution()
                            } else {
                                showCollectionRunnerPane = false
                                appState.sendSelectedAPIRequest()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if appState.isAPIRunning {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.75)
                                    Text("Cancel")
                                } else {
                                    Image(systemName: "paperplane.fill")
                                        .font(.system(size: 10.5))
                                    Text("Send")
                                }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(appState.isAPIRunning ? CeptraTheme.failure : CeptraTheme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send Request (⌘↩)")
                    }

                    if request.url.contains("{{") || !request.queryParams.filter(\.isEnabled).isEmpty {
                        HStack(spacing: 6) {
                            Text("Resolved:")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(CeptraTheme.textMuted)
                            Text(resolvedURL)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !missingVars.isEmpty {
                                Text("Unresolved: \(missingVars.joined(separator: ", "))")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.warning)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(CeptraTheme.sidebarBG.opacity(0.65))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CeptraTheme.border).frame(height: 1)
                }

                // Request Editor Tab Strip
                HStack(spacing: 2) {
                    ForEach(RequestEditorTab.allCases) { tab in
                        let selected = activeRequestTab == tab
                        let badge = requestTabCountBadge(tab, request: request)
                        Button {
                            activeRequestTab = tab
                        } label: {
                            HStack(spacing: 4) {
                                Text(tab.rawValue)
                                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                                if let badge {
                                    Text(badge)
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(selected ? CeptraTheme.accent : CeptraTheme.textMuted)
                                }
                            }
                            .foregroundStyle(selected ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(selected ? CeptraTheme.hoverBG : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CeptraTheme.border).frame(height: 1)
                }

                // Request Editor Body
                requestEditorContent(for: request)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Resizable Divider between Request & Response
                CeptraSplitResizeHandle(
                    axis: .vertical,
                    cursorDirection: .both,
                    onDragStart: { responseDragStart = effResp },
                    onDragChanged: { delta in
                        responseHeight = min(max(responseDragStart - delta, minResp), maxResp)
                    },
                    onDragEnd: {},
                    onDoubleClick: { responseHeight = 260 }
                )

                // Response / Collection Runner Pane
                responseAndRunnerPane(collection: collection, request: request, effectiveAuth: effectiveAuth, mergedVars: mergedVars)
                    .frame(height: effResp)
            }
        }
    }

    private func requestTabCountBadge(_ tab: RequestEditorTab, request: APIRequestItem) -> String? {
        switch tab {
        case .params:
            let n = request.queryParams.filter(\.isEnabled).count
            return n > 0 ? "\(n)" : nil
        case .headers:
            let n = request.headers.filter(\.isEnabled).count
            return n > 0 ? "\(n)" : nil
        case .auth:
            return request.auth.kind == .none || request.auth.kind == .inherit ? nil : "•"
        case .body:
            return request.body.mode == .none ? nil : request.body.mode.displayName
        case .assertions:
            let n = request.assertions.filter(\.isEnabled).count
            return n > 0 ? "\(n)" : nil
        case .extractors:
            let n = request.extractors.filter(\.isEnabled).count
            return n > 0 ? "\(n)" : nil
        case .scripts:
            return (!request.preRequestScript.isEmpty || !request.postResponseScript.isEmpty) ? "•" : nil
        }
    }

    @ViewBuilder
    private func requestEditorContent(for request: APIRequestItem) -> some View {
        switch activeRequestTab {
        case .params:
            keyValueEditor(
                items: request.queryParams,
                keyPlaceholder: "Parameter",
                valuePlaceholder: "Value or {{variable}}",
                addLabel: "Add Query Param"
            ) { updated in
                var r = request; r.queryParams = updated; appState.updateAPIRequest(r)
            }

        case .headers:
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("Quick Add:")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CeptraTheme.textMuted)
                    quickHeaderChip("Accept: application/json", key: "Accept", value: "application/json", request: request)
                    quickHeaderChip("Content-Type: JSON", key: "Content-Type", value: "application/json", request: request)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                keyValueEditor(
                    items: request.headers,
                    keyPlaceholder: "Header",
                    valuePlaceholder: "Value or {{variable}}",
                    addLabel: "Add Header"
                ) { updated in
                    var r = request; r.headers = updated; appState.updateAPIRequest(r)
                }
            }

        case .auth:
            authEditor(for: request)

        case .body:
            bodyEditor(for: request)

        case .assertions:
            assertionsEditor(for: request)

        case .extractors:
            extractorsEditor(for: request)

        case .scripts:
            scriptsEditor(for: request)
        }
    }

    private func quickHeaderChip(_ title: String, key: String, value: String, request: APIRequestItem) -> some View {
        Button(title) {
            var r = request
            if let idx = r.headers.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
                r.headers[idx].value = value
                r.headers[idx].isEnabled = true
            } else {
                r.headers.append(APIKeyValueItem(key: key, value: value))
            }
            appState.updateAPIRequest(r)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(CeptraTheme.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(CeptraTheme.hoverBG, in: Capsule())
        .buttonStyle(.plain)
    }

    private func keyValueEditor(
        items: [APIKeyValueItem],
        keyPlaceholder: String,
        valuePlaceholder: String,
        addLabel: String,
        allowFilePath: Bool = false,
        onChange: @escaping ([APIKeyValueItem]) -> Void
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { item.isEnabled },
                            set: { var copy = items; copy[idx].isEnabled = $0; onChange(copy) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()

                        TextField(keyPlaceholder, text: Binding(
                            get: { item.key },
                            set: { var copy = items; copy[idx].key = $0; onChange(copy) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                        TextField(valuePlaceholder, text: Binding(
                            get: { item.value },
                            set: { var copy = items; copy[idx].value = $0; onChange(copy) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                        if allowFilePath {
                            Button {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = true
                                panel.canChooseDirectories = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    var copy = items
                                    copy[idx].filePath = url.path
                                    copy[idx].value = url.lastPathComponent
                                    onChange(copy)
                                }
                            } label: {
                                Image(systemName: item.filePath != nil ? "doc.fill" : "paperclip")
                                    .font(.system(size: 11))
                                    .foregroundStyle(item.filePath != nil ? CeptraTheme.accent : CeptraTheme.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .help(item.filePath ?? "Attach File")
                        }

                        Button {
                            var copy = items
                            copy.remove(at: idx)
                            onChange(copy)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    var copy = items
                    copy.append(APIKeyValueItem())
                    onChange(copy)
                } label: {
                    Label(addLabel, systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(12)
        }
    }

    private func authEditor(for request: APIRequestItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Auth Type")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                        .frame(width: 90, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { request.auth.kind },
                        set: { var r = request; r.auth.kind = $0; appState.updateAPIRequest(r) }
                    )) {
                        ForEach(APIAuthConfig.Kind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                switch request.auth.kind {
                case .inherit:
                    Text("Inherits authentication from its parent folder or collection.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textMuted)
                case .none:
                    Text("This request will be sent without authentication headers.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(CeptraTheme.textMuted)
                case .bearer:
                    labeledField("Token", placeholder: "{{authToken}} or Bearer token", text: Binding(
                        get: { request.auth.bearerToken },
                        set: { var r = request; r.auth.bearerToken = $0; appState.updateAPIRequest(r) }
                    ))
                case .basic:
                    labeledField("Username", placeholder: "{{username}}", text: Binding(
                        get: { request.auth.basicUsername },
                        set: { var r = request; r.auth.basicUsername = $0; appState.updateAPIRequest(r) }
                    ))
                    labeledField("Password", placeholder: "{{password}}", text: Binding(
                        get: { request.auth.basicPassword },
                        set: { var r = request; r.auth.basicPassword = $0; appState.updateAPIRequest(r) }
                    ))
                case .apiKey:
                    labeledField("Key Name", placeholder: "X-API-Key", text: Binding(
                        get: { request.auth.apiKeyName },
                        set: { var r = request; r.auth.apiKeyName = $0; appState.updateAPIRequest(r) }
                    ))
                    labeledField("Value", placeholder: "{{apiKey}}", text: Binding(
                        get: { request.auth.apiKeyValue },
                        set: { var r = request; r.auth.apiKeyValue = $0; appState.updateAPIRequest(r) }
                    ))
                    HStack(spacing: 10) {
                        Text("Add to")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CeptraTheme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { request.auth.apiKeyIn },
                            set: { var r = request; r.auth.apiKeyIn = $0; appState.updateAPIRequest(r) }
                        )) {
                            ForEach(APIKeyLocation.allCases) { loc in
                                Text(loc.displayName).tag(loc)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
            }
            .padding(14)
        }
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CeptraTheme.textSecondary)
                .frame(width: 90, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func bodyEditor(for request: APIRequestItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { request.body.mode },
                    set: { var r = request; r.body.mode = $0; appState.updateAPIRequest(r) }
                )) {
                    ForEach(APIBodyConfig.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 170)

                if request.body.mode == .json {
                    Button("Format JSON") {
                        var r = request
                        r.body.rawText = APIRequestRunner.prettyPrintIfJSON(r.body.rawText)
                        appState.updateAPIRequest(r)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if request.body.mode == .raw {
                    TextField("Content-Type", text: Binding(
                        get: { request.body.rawContentType },
                        set: { var r = request; r.body.rawContentType = $0; appState.updateAPIRequest(r) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(width: 180)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            switch request.body.mode {
            case .none:
                Text("No body will be sent with this request.")
                    .font(.system(size: 12))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .json, .raw:
                TextEditor(text: Binding(
                    get: { request.body.rawText },
                    set: { var r = request; r.body.rawText = $0; appState.updateAPIRequest(r) }
                ))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(CeptraTheme.panelBG)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CeptraTheme.border, lineWidth: 1))
                .padding([.horizontal, .bottom], 12)

            case .formURLEncoded:
                keyValueEditor(
                    items: request.body.formItems,
                    keyPlaceholder: "Field",
                    valuePlaceholder: "Value",
                    addLabel: "Add Form Field"
                ) { updated in
                    var r = request; r.body.formItems = updated; appState.updateAPIRequest(r)
                }

            case .multipartFormData:
                keyValueEditor(
                    items: request.body.formItems,
                    keyPlaceholder: "Field",
                    valuePlaceholder: "Value or attach file",
                    addLabel: "Add Multipart Field",
                    allowFilePath: true
                ) { updated in
                    var r = request; r.body.formItems = updated; appState.updateAPIRequest(r)
                }

            case .graphql:
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("QUERY")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textMuted)
                        TextEditor(text: Binding(
                            get: { request.body.graphqlQuery },
                            set: { var r = request; r.body.graphqlQuery = $0; appState.updateAPIRequest(r) }
                        ))
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CeptraTheme.border, lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VARIABLES (JSON)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textMuted)
                        TextEditor(text: Binding(
                            get: { request.body.graphqlVariables },
                            set: { var r = request; r.body.graphqlVariables = $0; appState.updateAPIRequest(r) }
                        ))
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CeptraTheme.border, lineWidth: 1))
                    }
                }
                .padding([.horizontal, .bottom], 12)
            }
        }
    }

    private func assertionsEditor(for request: APIRequestItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Button("+ Status 200") {
                        var r = request
                        r.assertions.append(APIAssertionRule(name: "Status is 200", target: .statusCode, op: .equals, expectedValue: "200"))
                        appState.updateAPIRequest(r)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("+ Latency < 1000ms") {
                        var r = request
                        r.assertions.append(APIAssertionRule(name: "Fast response", target: .responseTimeMs, op: .lessThan, expectedValue: "1000"))
                        appState.updateAPIRequest(r)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("+ JSONPath Rule") {
                        var r = request
                        r.assertions.append(APIAssertionRule(name: "JSON field check", target: .jsonPath, property: "$.id", op: .exists, expectedValue: ""))
                        appState.updateAPIRequest(r)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }

                ForEach(Array(request.assertions.enumerated()), id: \.element.id) { idx, rule in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { var r = request; r.assertions[idx].isEnabled = $0; appState.updateAPIRequest(r) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()

                        Picker("", selection: Binding(
                            get: { rule.target },
                            set: { var r = request; r.assertions[idx].target = $0; appState.updateAPIRequest(r) }
                        )) {
                            ForEach(APIAssertionRule.Target.allCases) { t in
                                Text(t.displayName).tag(t)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 132)

                        if rule.target == .jsonPath || rule.target == .header {
                            TextField(rule.target == .jsonPath ? "$.data.id" : "Content-Type", text: Binding(
                                get: { rule.property },
                                set: { var r = request; r.assertions[idx].property = $0; appState.updateAPIRequest(r) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 140)
                        }

                        Picker("", selection: Binding(
                            get: { rule.op },
                            set: { var r = request; r.assertions[idx].op = $0; appState.updateAPIRequest(r) }
                        )) {
                            ForEach(APIAssertionRule.OperatorKind.allCases) { op in
                                Text(op.displayName).tag(op)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 108)

                        if rule.op != .exists {
                            TextField("Expected", text: Binding(
                                get: { rule.expectedValue },
                                set: { var r = request; r.assertions[idx].expectedValue = $0; appState.updateAPIRequest(r) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                        }

                        Button {
                            var r = request
                            r.assertions.remove(at: idx)
                            appState.updateAPIRequest(r)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
        }
    }

    private func extractorsEditor(for request: APIRequestItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Extract values from this response into {{variables}} for chaining subsequent requests (e.g. login token → authorized endpoints).")
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textMuted)

                ForEach(Array(request.extractors.enumerated()), id: \.element.id) { idx, ext in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { ext.isEnabled },
                            set: { var r = request; r.extractors[idx].isEnabled = $0; appState.updateAPIRequest(r) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()

                        Picker("", selection: Binding(
                            get: { ext.source },
                            set: { var r = request; r.extractors[idx].source = $0; appState.updateAPIRequest(r) }
                        )) {
                            ForEach(APIVariableExtractor.Source.allCases) { s in
                                Text(s.displayName).tag(s)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)

                        TextField("$.access_token", text: Binding(
                            get: { ext.expression },
                            set: { var r = request; r.extractors[idx].expression = $0; appState.updateAPIRequest(r) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))

                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundStyle(CeptraTheme.textMuted)

                        TextField("varName", text: Binding(
                            get: { ext.targetVariableName },
                            set: { var r = request; r.extractors[idx].targetVariableName = $0; appState.updateAPIRequest(r) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 120)

                        Picker("", selection: Binding(
                            get: { ext.scope },
                            set: { var r = request; r.extractors[idx].scope = $0; appState.updateAPIRequest(r) }
                        )) {
                            ForEach(APIVariableExtractor.Scope.allCases) { sc in
                                Text(sc.displayName).tag(sc)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 136)

                        Button {
                            var r = request
                            r.extractors.remove(at: idx)
                            appState.updateAPIRequest(r)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    var r = request
                    r.extractors.append(APIVariableExtractor(source: .jsonPath, expression: "$.token", targetVariableName: "authToken", scope: .environment))
                    appState.updateAPIRequest(r)
                } label: {
                    Label("Add Variable Extractor", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
    }

    private func scriptsEditor(for request: APIRequestItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PRE-REQUEST SCRIPT (PRESERVED ON EXPORT)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textMuted)
                TextEditor(text: Binding(
                    get: { request.preRequestScript },
                    set: { var r = request; r.preRequestScript = $0; appState.updateAPIRequest(r) }
                ))
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CeptraTheme.border, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("POST-RESPONSE / TEST SCRIPT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textMuted)
                    Spacer()
                    if !request.postResponseScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Extract Rules") {
                            let (rules, exts) = APIFormatCodec.parsePostmanTestScriptHints(request.postResponseScript)
                            var r = request
                            r.assertions.append(contentsOf: rules)
                            r.extractors.append(contentsOf: exts)
                            appState.updateAPIRequest(r)
                            appState.showBanner("Extracted \(rules.count) assertion(s) & \(exts.count) variable extractor(s)")
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                TextEditor(text: Binding(
                    get: { request.postResponseScript },
                    set: { var r = request; r.postResponseScript = $0; appState.updateAPIRequest(r) }
                ))
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CeptraTheme.border, lineWidth: 1))
            }
        }
        .padding(12)
    }

    // MARK: - Response & Collection Runner Bottom Pane

    private func responseAndRunnerPane(
        collection: APICollection,
        request: APIRequestItem,
        effectiveAuth: APIAuthConfig,
        mergedVars: [String: String]
    ) -> some View {
        VStack(spacing: 0) {
            // Header Strip
            HStack(spacing: 8) {
                if appState.apiCollectionRunSummary != nil || appState.apiCollectionRunProgress != nil {
                    Picker("", selection: $showCollectionRunnerPane) {
                        Text("Response").tag(false)
                        Text("Collection Run").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 196)
                }

                if !showCollectionRunnerPane {
                    ForEach(ResponseViewerTab.allCases) { tab in
                        let selected = activeResponseTab == tab
                        Button {
                            activeResponseTab = tab
                        } label: {
                            Text(responseTabTitle(tab))
                                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(selected ? CeptraTheme.hoverBG : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 8)

                if let res = appState.apiLastResult, !showCollectionRunnerPane {
                    statusMetricsBadges(res)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(CeptraTheme.sidebarBG)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }

            if showCollectionRunnerPane {
                collectionRunnerView
            } else {
                singleResponseView(collection: collection, request: request, effectiveAuth: effectiveAuth, mergedVars: mergedVars)
            }
        }
        .background(CeptraTheme.canvasBG)
    }

    private func responseTabTitle(_ tab: ResponseViewerTab) -> String {
        guard let res = appState.apiLastResult else {
            return tab == .history && !appState.apiExecutionHistory.isEmpty ? "History (\(appState.apiExecutionHistory.count))" : tab.rawValue
        }
        switch tab {
        case .headers: return "Headers (\(res.responseHeaders.count))"
        case .cookies: return "Cookies (\(res.cookies.count))"
        case .assertions:
            let pass = res.assertionResults.filter(\.passed).count
            return res.assertionResults.isEmpty ? "Assertions" : "Assertions (\(pass)/\(res.assertionResults.count))"
        case .history:
            return "History (\(appState.apiExecutionHistory.count))"
        default:
            return tab.rawValue
        }
    }

    @ViewBuilder
    private func statusMetricsBadges(_ res: APIExecutionResult) -> some View {
        HStack(spacing: 8) {
            if let code = res.statusCode {
                let color: Color = code < 300 ? CeptraTheme.success : (code < 400 ? CeptraTheme.cyan : (code < 500 ? CeptraTheme.warning : CeptraTheme.failure))
                Text("\(code) \(res.statusText ?? "")")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.14), in: Capsule())
            } else if res.errorMessage != nil {
                Text("ERROR")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.failure)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(CeptraTheme.failure.opacity(0.14), in: Capsule())
            }
            Text("\(res.durationMs) ms")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CeptraTheme.textSecondary)
            Text(ByteCountFormatter.string(fromByteCount: Int64(res.responseBodyByteCount), countStyle: .memory))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(CeptraTheme.textMuted)
        }
    }

    @ViewBuilder
    private func singleResponseView(
        collection: APICollection,
        request: APIRequestItem,
        effectiveAuth: APIAuthConfig,
        mergedVars: [String: String]
    ) -> some View {
        switch activeResponseTab {
        case .code:
            let generated = APICodeGenerator.snippet(
                for: request,
                effectiveAuth: effectiveAuth,
                variables: mergedVars,
                language: selectedSnippetLang
            )
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("", selection: $selectedSnippetLang) {
                        ForEach(APICodeSnippetLanguage.allCases) { lang in
                            Text(lang.rawValue).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    Spacer()
                    Button("Copy Snippet") {
                        appState.copyTextToPasteboard(generated, label: "\(selectedSnippetLang.rawValue) snippet")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Generate Full Suite File…") {
                        appState.generateAutomatedTestSuiteFile(from: collection)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CeptraTheme.accent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)

                ScrollView {
                    Text(generated)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(CeptraTheme.panelBG)
            }

        case .history:
            if appState.apiExecutionHistory.isEmpty {
                emptyResponseHint("Send requests to build your live execution history.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(appState.apiExecutionHistory) { item in
                            Button {
                                appState.apiLastResult = item
                                activeResponseTab = .body
                            } label: {
                                HStack(spacing: 8) {
                                    Text(item.method.rawValue)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(methodColor(item.method))
                                        .frame(width: 44, alignment: .leading)
                                    Text(item.requestName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(CeptraTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(item.resolvedURL)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.textMuted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if let code = item.statusCode {
                                        Text("\(code)")
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(code < 400 ? CeptraTheme.success : CeptraTheme.failure)
                                    }
                                    Text("\(item.durationMs)ms")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.textMuted)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(appState.apiLastResult?.id == item.id ? CeptraTheme.activeBG : CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
            }

        default:
            if let res = appState.apiLastResult {
                switch activeResponseTab {
                case .body:
                    VStack(spacing: 0) {
                        if let err = res.errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(CeptraTheme.failure)
                                Text(err)
                                    .font(.system(size: 12))
                                    .foregroundStyle(CeptraTheme.failure)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                            .padding(12)
                            .background(CeptraTheme.failure.opacity(0.1))
                        } else {
                            HStack(spacing: 8) {
                                Picker("", selection: $prettyPrintResponse) {
                                    Text("Pretty").tag(true)
                                    Text("Raw").tag(false)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 130)

                                if let t = res.timings {
                                    timingSummaryRow(t)
                                }

                                Spacer()

                                Button("Copy Body") {
                                    appState.copyTextToPasteboard(prettyPrintResponse ? res.prettyResponseBody : res.responseBody, label: "response body")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)

                            if !res.extractedVariables.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(CeptraTheme.accent)
                                    Text("Extracted:")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(CeptraTheme.textSecondary)
                                    ForEach(res.extractedVariables.keys.sorted(), id: \.self) { k in
                                        Text("{{\(k)}} = \(res.extractedVariables[k] ?? "")")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(CeptraTheme.cyan)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 6)
                            }

                            ScrollView {
                                Text(prettyPrintResponse ? res.prettyResponseBody : res.responseBody)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            .background(CeptraTheme.panelBG)
                        }
                    }

                case .headers:
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(res.responseHeaders) { h in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(h.key)
                                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.cyan)
                                        .frame(width: 210, alignment: .leading)
                                        .textSelection(.enabled)
                                    Text(h.value)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.textPrimary)
                                        .textSelection(.enabled)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                            }
                        }
                        .padding(.vertical, 8)
                    }

                case .cookies:
                    if res.cookies.isEmpty {
                        emptyResponseHint("No Set-Cookie headers returned by this endpoint.")
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(res.cookies) { c in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(c.name)=\(c.value)")
                                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                            .textSelection(.enabled)
                                        Text("\(c.domain)\(c.path) \(c.attributes)")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(CeptraTheme.textMuted)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }

                case .assertions:
                    if res.assertionResults.isEmpty {
                        emptyResponseHint("Add rules in the Assertions tab to validate status, latency, headers, or JSONPath fields.")
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(res.assertionResults) { a in
                                    HStack(spacing: 8) {
                                        Image(systemName: a.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(a.passed ? CeptraTheme.success : CeptraTheme.failure)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(a.title)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(CeptraTheme.textPrimary)
                                            if let msg = a.message {
                                                Text(msg)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(CeptraTheme.failure)
                                            } else if let actual = a.actual {
                                                Text("Actual: \(actual)")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(CeptraTheme.textMuted)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background((a.passed ? CeptraTheme.success : CeptraTheme.failure).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            .padding(10)
                        }
                    }

                default:
                    EmptyView()
                }
            } else {
                emptyResponseHint("Press Send (⌘↩) to execute this request and inspect Body, Headers, Cookies, Timings, and Assertions.")
            }
        }
    }

    private func timingSummaryRow(_ t: TimeTravelNetworkTimings) -> some View {
        HStack(spacing: 8) {
            if let dns = t.dnsMs { timingChip("DNS", ms: dns) }
            if let tcp = t.connectMs { timingChip("TCP", ms: tcp) }
            if let tls = t.tlsMs { timingChip("TLS", ms: tls) }
            if let ttfb = t.ttfbMs { timingChip("TTFB", ms: ttfb) }
            if let dl = t.downloadMs { timingChip("DL", ms: dl) }
        }
    }

    private func timingChip(_ label: String, ms: Int) -> some View {
        Text("\(label) \(ms)ms")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(CeptraTheme.textMuted)
    }

    private var collectionRunnerView: some View {
        VStack(spacing: 0) {
            if let prog = appState.apiCollectionRunProgress {
                HStack(spacing: 10) {
                    ProgressView(value: Double(prog.completed), total: Double(max(1, prog.total)))
                        .frame(maxWidth: 240)
                    Text("Running \(prog.completed) / \(prog.total)…")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Spacer()
                }
                .padding(12)
            }

            if let summary = appState.apiCollectionRunSummary {
                HStack(spacing: 10) {
                    Text(summary.collectionName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Text("\(summary.passedCount) passed")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.success)
                    if summary.failedCount > 0 {
                        Text("\(summary.failedCount) failed")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CeptraTheme.failure)
                    }
                    Text("\(summary.totalDurationMs) ms")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                    Spacer()

                    Button("Open in Replay") {
                        appState.openAPICollectionRunInReplay(summary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Export Replay HTML…") {
                        appState.exportAPICollectionRunReplayHTML(summary)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CeptraTheme.accent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CeptraTheme.border).frame(height: 1)
                }

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(summary.results) { item in
                            Button {
                                appState.apiLastResult = item
                                showCollectionRunnerPane = false
                                activeResponseTab = item.assertionResults.isEmpty ? .body : .assertions
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(item.isSuccess ? CeptraTheme.success : CeptraTheme.failure)
                                    Text(item.method.rawValue)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(methodColor(item.method))
                                        .frame(width: 44, alignment: .leading)
                                    Text(item.requestName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(CeptraTheme.textPrimary)
                                    if !item.folderPath.isEmpty {
                                        Text(item.folderPath)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(CeptraTheme.textMuted)
                                    }
                                    Spacer()
                                    if !item.assertionResults.isEmpty {
                                        let pass = item.assertionResults.filter(\.passed).count
                                        Text("Tests \(pass)/\(item.assertionResults.count)")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(item.allAssertionsPassed ? CeptraTheme.success : CeptraTheme.failure)
                                    }
                                    if let code = item.statusCode {
                                        Text("\(code)")
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(code < 400 ? CeptraTheme.success : CeptraTheme.failure)
                                    }
                                    Text("\(item.durationMs)ms")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.textMuted)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
            } else if appState.apiCollectionRunProgress == nil {
                emptyResponseHint("Click Run Collection in the toolbar to execute every request sequentially with variable chaining.")
            }
        }
    }

    private func emptyResponseHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(CeptraTheme.textMuted)
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyWorkspaceStage: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "network")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(CeptraTheme.cyan)
                Text("Ceptra API Client Studio")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                Text("Import, edit, run, and export collections & environments from Postman, Insomnia, OpenAPI, HAR, .http, or cURL — without leaving Ceptra.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                HStack(spacing: 8) {
                    Button("Import Postman / Insomnia / OpenAPI…") {
                        appState.presentImportAPIFilePanel()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CeptraTheme.accent)

                    Button("Import cURL…") {
                        showingImportCurlSheet = true
                    }
                    .buttonStyle(.bordered)

                    Button("Generate Sample Files on Disk…") {
                        appState.generateSampleAPIImportFilesPanel()
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("TRY LIVE RUNNABLE EXAMPLES")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(CeptraTheme.textMuted)
                        Spacer()
                        Button("Load All 3 Examples") {
                            appState.loadAllAPIExamples()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CeptraTheme.accent)
                        .buttonStyle(.plain)
                    }

                    ForEach(APIStudioStore.ExampleTemplate.allCases) { tpl in
                        Button {
                            appState.loadAPIExample(tpl)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tpl.symbolName)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(CeptraTheme.cyan)
                                    .frame(width: 28, height: 28)
                                    .background(CeptraTheme.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tpl.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(CeptraTheme.textPrimary)
                                    Text(tpl.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(CeptraTheme.textMuted)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(CeptraTheme.accent)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 520)
                .padding(.top, 6)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .background(CeptraTheme.canvasBG)
    }

    private func shortMethodLabel(_ method: APIHTTPMethod) -> String {
        switch method {
        case .delete: return "DEL"
        case .options: return "OPT"
        case .patch: return "PAT"
        default: return method.rawValue
        }
    }

    private func methodColor(_ method: APIHTTPMethod) -> Color {
        switch method {
        case .get: return CeptraTheme.success
        case .post: return CeptraTheme.accent
        case .put: return CeptraTheme.accentWarm
        case .patch: return CeptraTheme.violet
        case .delete: return CeptraTheme.failure
        case .head, .options: return CeptraTheme.cyan
        }
    }
}

// MARK: - Environment Manager Sheet

struct APIEnvironmentManagerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedEnvID: UUID?
    @State private var revealedSecretIDs: Set<UUID> = []
    @State private var redactSecretsOnExport: Bool = true

    private var selectedEnv: APIEnvironment? {
        if let id = selectedEnvID, let found = appState.apiEnvironments.first(where: { $0.id == id }) {
            return found
        }
        return appState.apiEnvironments.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Environments & Variables", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button("Import Environment…") {
                    appState.presentImportAPIFilePanel()
                }
                .controlSize(.small)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(CeptraTheme.sidebarBG)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CeptraTheme.border).frame(height: 1)
            }

            HStack(spacing: 0) {
                // Left list of environments
                VStack(spacing: 6) {
                    HStack {
                        Text("ENVIRONMENTS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textMuted)
                        Spacer()
                        Button {
                            let created = appState.createAPIEnvironment()
                            selectedEnvID = created.id
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)

                    List(selection: $selectedEnvID) {
                        ForEach(appState.apiEnvironments) { env in
                            HStack {
                                Circle()
                                    .fill(appState.apiActiveEnvironmentID == env.id ? CeptraTheme.success : Color.clear)
                                    .frame(width: 6, height: 6)
                                Text(env.name)
                                    .font(.system(size: 12, weight: appState.apiActiveEnvironmentID == env.id ? .semibold : .regular))
                                Spacer()
                                Text("\(env.variables.count)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.textMuted)
                            }
                            .tag(env.id)
                            .contextMenu {
                                Button("Set as Active") {
                                    appState.apiActiveEnvironmentID = env.id
                                    appState.saveAPIStudio()
                                }
                                Button("Duplicate") { appState.duplicateAPIEnvironment(id: env.id) }
                                Button("Delete", role: .destructive) { appState.deleteAPIEnvironment(id: env.id) }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
                .frame(width: 210)
                .background(CeptraTheme.sidebarBG)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(CeptraTheme.border).frame(width: 1)
                }

                // Right variable editor
                if let env = selectedEnv {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            TextField("Environment Name", text: Binding(
                                get: { env.name },
                                set: { var copy = env; copy.name = $0; appState.updateAPIEnvironment(copy) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, weight: .semibold))

                            Button(appState.apiActiveEnvironmentID == env.id ? "Active" : "Set Active") {
                                appState.apiActiveEnvironmentID = env.id
                                appState.saveAPIStudio()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(appState.apiActiveEnvironmentID == env.id ? CeptraTheme.success : CeptraTheme.accent)
                            .controlSize(.small)

                            Menu("Export") {
                                ForEach(APIExportEnvironmentFormat.allCases) { fmt in
                                    Button(fmt.rawValue) {
                                        appState.exportAPIEnvironment(env, format: fmt, redactSecrets: redactSecretsOnExport)
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(12)

                        HStack {
                            Toggle("Redact secret values when exporting", isOn: $redactSecretsOnExport)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11.5))
                            Spacer()
                            Text("Current Value overrides Initial Value locally during runs")
                                .font(.system(size: 10.5))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(CeptraTheme.border).frame(height: 1)
                        }

                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text("").frame(width: 20)
                                    Text("KEY").frame(maxWidth: .infinity, alignment: .leading)
                                    Text("INITIAL (SHARED)").frame(maxWidth: .infinity, alignment: .leading)
                                    Text("CURRENT (LOCAL)").frame(maxWidth: .infinity, alignment: .leading)
                                    Text("").frame(width: 56)
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(CeptraTheme.textMuted)

                                ForEach(Array(env.variables.enumerated()), id: \.element.id) { idx, v in
                                    let isMasked = v.isSecret && !revealedSecretIDs.contains(v.id)
                                    HStack(spacing: 6) {
                                        Toggle("", isOn: Binding(
                                            get: { v.isEnabled },
                                            set: { var copy = env; copy.variables[idx].isEnabled = $0; appState.updateAPIEnvironment(copy) }
                                        ))
                                        .toggleStyle(.checkbox)
                                        .labelsHidden()

                                        TextField("key", text: Binding(
                                            get: { v.key },
                                            set: { var copy = env; copy.variables[idx].key = $0; appState.updateAPIEnvironment(copy) }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11.5, design: .monospaced))

                                        Group {
                                            if isMasked {
                                                SecureField("initial", text: Binding(
                                                    get: { v.initialValue },
                                                    set: { var copy = env; copy.variables[idx].initialValue = $0; appState.updateAPIEnvironment(copy) }
                                                ))
                                            } else {
                                                TextField("initial", text: Binding(
                                                    get: { v.initialValue },
                                                    set: { var copy = env; copy.variables[idx].initialValue = $0; appState.updateAPIEnvironment(copy) }
                                                ))
                                            }
                                        }
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11.5, design: .monospaced))

                                        Group {
                                            if isMasked {
                                                SecureField("current", text: Binding(
                                                    get: { v.currentValue },
                                                    set: { var copy = env; copy.variables[idx].currentValue = $0; appState.updateAPIEnvironment(copy) }
                                                ))
                                            } else {
                                                TextField("current", text: Binding(
                                                    get: { v.currentValue },
                                                    set: { var copy = env; copy.variables[idx].currentValue = $0; appState.updateAPIEnvironment(copy) }
                                                ))
                                            }
                                        }
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11.5, design: .monospaced))

                                        Button {
                                            var copy = env
                                            copy.variables[idx].isSecret.toggle()
                                            appState.updateAPIEnvironment(copy)
                                        } label: {
                                            Image(systemName: v.isSecret ? "lock.fill" : "lock.open")
                                                .font(.system(size: 11))
                                                .foregroundStyle(v.isSecret ? CeptraTheme.accentWarm : CeptraTheme.textMuted)
                                        }
                                        .buttonStyle(.plain)
                                        .help(v.isSecret ? "Marked as secret (click to unmark)" : "Mark as secret")

                                        if v.isSecret {
                                            Button {
                                                if revealedSecretIDs.contains(v.id) { revealedSecretIDs.remove(v.id) }
                                                else { revealedSecretIDs.insert(v.id) }
                                            } label: {
                                                Image(systemName: isMasked ? "eye" : "eye.slash")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(CeptraTheme.textMuted)
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        Button {
                                            var copy = env
                                            copy.variables.remove(at: idx)
                                            appState.updateAPIEnvironment(copy)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11))
                                                .foregroundStyle(CeptraTheme.textMuted)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                Button {
                                    var copy = env
                                    copy.variables.append(APIEnvironmentVariable())
                                    appState.updateAPIEnvironment(copy)
                                } label: {
                                    Label("Add Variable", systemImage: "plus")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(CeptraTheme.accent)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 4)
                            }
                            .padding(12)
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Text("No environments yet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(CeptraTheme.textSecondary)
                        Button("Create Environment") {
                            let created = appState.createAPIEnvironment()
                            selectedEnvID = created.id
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CeptraTheme.accent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 460)
        .background(CeptraTheme.canvasBG)
        .onAppear {
            selectedEnvID = appState.apiActiveEnvironmentID ?? appState.apiEnvironments.first?.id
        }
    }
}

// MARK: - Import cURL Sheet

struct APIImportCurlSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var curlText: String = ""
    @State private var targetCollectionID: UUID?

    private var previewRequests: [APIRequestItem] {
        APIFormatCodec.parseCurlCommands(curlText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Import cURL Command(s)", systemImage: "terminal")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Paste from Clipboard") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        curlText = s
                    }
                }
                .controlSize(.small)
            }

            TextEditor(text: $curlText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 150)
                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(CeptraTheme.border, lineWidth: 1))

            HStack {
                Text("Target Collection:")
                    .font(.system(size: 12))
                    .foregroundStyle(CeptraTheme.textSecondary)
                Picker("", selection: $targetCollectionID) {
                    Text("New Collection").tag(UUID?.none)
                    ForEach(appState.apiCollections) { col in
                        Text(col.name).tag(UUID?.some(col.id))
                    }
                }
                .labelsHidden()
                Spacer()
                Text(previewRequests.isEmpty ? "No cURL detected yet" : "Detected \(previewRequests.count) request(s)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(previewRequests.isEmpty ? CeptraTheme.textMuted : CeptraTheme.success)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    appState.importAPICurl(curlText, targetCollectionID: targetCollectionID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(CeptraTheme.accent)
                .disabled(previewRequests.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560, height: 320)
        .background(CeptraTheme.canvasBG)
        .onAppear {
            targetCollectionID = appState.selectedAPICollection?.id
        }
    }
}
