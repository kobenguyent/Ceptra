import AppKit
import CeptraCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum APIExportCollectionFormat: String, CaseIterable, Identifiable {
    case postmanV21 = "Postman Collection v2.1 (JSON)"
    case insomniaV4 = "Insomnia v4 Export (JSON)"
    case httpFile = "REST Client / JetBrains (.http)"
    case ceptraBundle = "Ceptra API Studio Bundle (JSON)"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .postmanV21: return "postman_collection.json"
        case .insomniaV4: return "insomnia_v4.json"
        case .httpFile: return "http"
        case .ceptraBundle: return "ceptra-api.json"
        }
    }

    var contentType: UTType {
        switch self {
        case .httpFile: return .plainText
        default: return .json
        }
    }
}

enum APIExportEnvironmentFormat: String, CaseIterable, Identifiable {
    case postmanEnvironment = "Postman Environment (JSON)"
    case insomniaV4Environment = "Insomnia v4 Environment (JSON)"
    case dotEnv = ".env File"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .postmanEnvironment: return "postman_environment.json"
        case .insomniaV4Environment: return "insomnia_env_v4.json"
        case .dotEnv: return "env"
        }
    }

    var contentType: UTType {
        switch self {
        case .dotEnv: return .plainText
        default: return .json
        }
    }
}

@MainActor
extension AppState {
    // MARK: - Navigation & Lifecycle

    func toggleAPIStudio() {
        isAPIStudioVisible.toggle()
        if isAPIStudioVisible {
            ensureAPIStudioLoaded()
        }
    }

    func openAPIStudio() {
        isAPIStudioVisible = true
        ensureAPIStudioLoaded()
    }

    func loadAPIStudioForCurrentWorkspace() {
        let loaded = apiStudioStore.load(workspaceRoot: workspace?.rootURL)
        apiCollections = loaded.collections
        apiEnvironments = loaded.environments
        apiActiveEnvironmentID = loaded.activeEnvironmentID
            ?? loaded.environments.first?.id
        apiSelectedCollectionID = loaded.collections.first?.id
        apiSelectedRequestID = loaded.collections.first?.flattenedRequests().first?.request.id
        apiLastResult = nil
        apiCollectionRunSummary = nil
        apiExecutionHistory = []
        apiHasLoadedStudio = true
    }

    func ensureAPIStudioLoaded() {
        if !apiHasLoadedStudio {
            loadAPIStudioForCurrentWorkspace()
        }
    }

    func saveAPIStudio() {
        let payload = APIStudioWorkspaceData(
            version: 1,
            collections: apiCollections,
            environments: apiEnvironments,
            activeEnvironmentID: apiActiveEnvironmentID
        )
        apiStudioStore.save(payload, workspaceRoot: workspace?.rootURL)
    }

    // MARK: - Active Selection Helpers

    var activeAPIEnvironment: APIEnvironment? {
        guard let id = apiActiveEnvironmentID else { return nil }
        return apiEnvironments.first(where: { $0.id == id })
    }

    var selectedAPICollection: APICollection? {
        if let cid = apiSelectedCollectionID,
           let found = apiCollections.first(where: { $0.id == cid }) {
            return found
        }
        if let rid = apiSelectedRequestID {
            return apiCollections.first(where: { $0.request(withID: rid) != nil })
        }
        return apiCollections.first
    }

    var selectedAPIRequestContext: (collection: APICollection, request: APIRequestItem, effectiveAuth: APIAuthConfig)? {
        guard let rid = apiSelectedRequestID else { return nil }
        for col in apiCollections {
            if let found = col.request(withID: rid) {
                return (col, found.request, found.effectiveAuth)
            }
        }
        return nil
    }

    var activeAPIMergedVariables: [String: String] {
        APIVariableResolver.mergedVariables(
            collection: selectedAPICollection,
            environment: activeAPIEnvironment
        )
    }

    func selectAPIRequest(id: UUID, inCollection collectionID: UUID) {
        apiSelectedCollectionID = collectionID
        apiSelectedRequestID = id
        if let prev = apiExecutionHistory.first(where: { $0.requestID == id }) {
            apiLastResult = prev
        }
    }

    // MARK: - Collection / Folder / Request CRUD

    @discardableResult
    func createAPICollection(name: String = "New Collection") -> APICollection {
        let initialReq = APIRequestItem(
            name: "GET Example",
            method: .get,
            url: "{{baseUrl}}/todos/1",
            headers: [APIKeyValueItem(key: "Accept", value: "application/json")],
            assertions: [APIAssertionRule(name: "Status 200", target: .statusCode, op: .equals, expectedValue: "200")]
        )
        let col = APICollection(
            name: name,
            variables: [APIKeyValueItem(key: "baseUrl", value: "https://jsonplaceholder.typicode.com")],
            requests: [initialReq]
        )
        apiCollections.append(col)
        apiSelectedCollectionID = col.id
        apiSelectedRequestID = initialReq.id
        saveAPIStudio()
        return col
    }

    func createStarterAPISample() {
        loadAPIExample(.restCRUDChaining)
    }

    func loadAPIExample(_ template: APIStudioStore.ExampleTemplate) {
        ensureAPIStudioLoaded()
        let ex = APIStudioStore.makeExample(template)
        apiCollections.append(ex.collection)
        for env in ex.environments {
            if let existing = apiEnvironments.first(where: { $0.name == env.name }) {
                apiActiveEnvironmentID = existing.id
            } else {
                apiEnvironments.append(env)
                apiActiveEnvironmentID = env.id
            }
        }
        apiSelectedCollectionID = ex.collection.id
        apiSelectedRequestID = ex.collection.flattenedRequests().first?.request.id
        saveAPIStudio()
        isAPIStudioVisible = true
        showBanner("Loaded example: \(template.shortTitle)")
    }

    func loadAllAPIExamples() {
        ensureAPIStudioLoaded()
        var lastCol: APICollection?
        for template in APIStudioStore.ExampleTemplate.allCases {
            let ex = APIStudioStore.makeExample(template)
            apiCollections.append(ex.collection)
            lastCol = ex.collection
            for env in ex.environments {
                if !apiEnvironments.contains(where: { $0.name == env.name }) {
                    apiEnvironments.append(env)
                }
            }
        }
        if let first = apiCollections.last(where: { $0.id == lastCol?.id }) ?? apiCollections.first {
            apiSelectedCollectionID = first.id
            apiSelectedRequestID = first.flattenedRequests().first?.request.id
        }
        if apiActiveEnvironmentID == nil {
            apiActiveEnvironmentID = apiEnvironments.first?.id
        }
        saveAPIStudio()
        isAPIStudioVisible = true
        showBanner("Loaded all \(APIStudioStore.ExampleTemplate.allCases.count) runnable API example collections")
    }

    func generateSampleAPIImportFilesPanel() {
        let panel = NSSavePanel()
        panel.title = "Create Sample API Collection & Environment Files"
        panel.message = "Generates Postman v2.1, Postman Environment, Insomnia v4, OpenAPI 3.0, .http, and .env sample files to test importing & exporting."
        panel.prompt = "Create Examples"
        panel.nameFieldStringValue = "api-examples"
        panel.canCreateDirectories = true
        if let root = workspace?.rootURL {
            panel.directoryURL = root
        }

        guard panel.runModal() == .OK, let dirURL = panel.url else { return }
        do {
            let files = try APIStudioStore.createSampleImportFiles(at: dirURL)
            if let root = workspace?.rootURL, dirURL.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
                rescanWorkspace()
                isSidebarVisible = true
                if let first = files.first {
                    pendingRevealTreePath = first.path
                }
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([dirURL])
            }
            showBanner("Created \(files.count) sample files (Postman, Insomnia, OpenAPI, .http, .env) in \(dirURL.lastPathComponent)/")
        } catch {
            showBanner("Could not create sample files: \(error.localizedDescription)", isError: true)
        }
    }

    func renameAPICollection(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = apiCollections.firstIndex(where: { $0.id == id }) else { return }
        apiCollections[idx].name = trimmed
        apiCollections[idx].updatedAt = Date()
        saveAPIStudio()
    }

    func duplicateAPICollection(id: UUID) {
        guard let src = apiCollections.first(where: { $0.id == id }) else { return }
        func cloneFolder(_ f: APIFolder) -> APIFolder {
            APIFolder(
                id: UUID(),
                name: f.name,
                description: f.description,
                auth: f.auth,
                folders: f.folders.map(cloneFolder),
                requests: f.requests.map { cloneRequest($0) }
            )
        }
        func cloneRequest(_ r: APIRequestItem) -> APIRequestItem {
            var copy = r
            copy.id = UUID()
            return copy
        }
        let copy = APICollection(
            id: UUID(),
            name: "\(src.name) Copy",
            description: src.description,
            sourceFormat: src.sourceFormat,
            auth: src.auth,
            variables: src.variables,
            folders: src.folders.map(cloneFolder),
            requests: src.requests.map(cloneRequest)
        )
        apiCollections.append(copy)
        apiSelectedCollectionID = copy.id
        apiSelectedRequestID = copy.flattenedRequests().first?.request.id
        saveAPIStudio()
    }

    func deleteAPICollection(id: UUID) {
        apiCollections.removeAll(where: { $0.id == id })
        if apiSelectedCollectionID == id {
            apiSelectedCollectionID = apiCollections.first?.id
            apiSelectedRequestID = apiCollections.first?.flattenedRequests().first?.request.id
        }
        saveAPIStudio()
    }

    func addAPIFolder(name: String = "New Folder", inCollection collectionID: UUID, parentFolderID: UUID? = nil) {
        guard let idx = apiCollections.firstIndex(where: { $0.id == collectionID }) else { return }
        let folder = APIFolder(name: name)
        apiCollections[idx].appendFolder(folder, toFolderID: parentFolderID)
        saveAPIStudio()
    }

    func renameAPIFolder(collectionID: UUID, folderID: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = apiCollections.firstIndex(where: { $0.id == collectionID }) else { return }
        apiCollections[idx].renameFolder(id: folderID, newName: trimmed)
        saveAPIStudio()
    }

    func deleteAPIFolder(collectionID: UUID, folderID: UUID) {
        guard let idx = apiCollections.firstIndex(where: { $0.id == collectionID }) else { return }
        apiCollections[idx].removeFolder(id: folderID)
        if let rid = apiSelectedRequestID, apiCollections[idx].request(withID: rid) == nil {
            apiSelectedRequestID = apiCollections[idx].flattenedRequests().first?.request.id
        }
        saveAPIStudio()
    }

    @discardableResult
    func addAPIRequest(
        name: String = "New Request",
        method: APIHTTPMethod = .get,
        url: String = "{{baseUrl}}/",
        inCollection collectionID: UUID,
        folderID: UUID? = nil
    ) -> APIRequestItem? {
        guard let idx = apiCollections.firstIndex(where: { $0.id == collectionID }) else { return nil }
        let req = APIRequestItem(name: name, method: method, url: url)
        apiCollections[idx].appendRequest(req, toFolderID: folderID)
        apiSelectedCollectionID = collectionID
        apiSelectedRequestID = req.id
        saveAPIStudio()
        return req
    }

    func updateAPIRequest(_ updated: APIRequestItem) {
        for idx in apiCollections.indices {
            if apiCollections[idx].updateRequest(updated) {
                saveAPIStudio()
                return
            }
        }
    }

    func updateAPICollection(_ updated: APICollection) {
        guard let idx = apiCollections.firstIndex(where: { $0.id == updated.id }) else { return }
        apiCollections[idx] = updated
        saveAPIStudio()
    }

    func duplicateAPIRequest(id: UUID, inCollection collectionID: UUID) {
        guard let idx = apiCollections.firstIndex(where: { $0.id == collectionID }),
              let found = apiCollections[idx].request(withID: id) else { return }
        var copy = found.request
        copy.id = UUID()
        copy.name = "\(found.request.name) Copy"
        apiCollections[idx].appendRequest(copy, toFolderID: nil)
        apiSelectedRequestID = copy.id
        saveAPIStudio()
    }

    func deleteAPIRequest(id: UUID, inCollection collectionID: UUID) {
        guard let idx = apiCollections.firstIndex(where: { $0.id == collectionID }) else { return }
        apiCollections[idx].removeRequest(id: id)
        if apiSelectedRequestID == id {
            apiSelectedRequestID = apiCollections[idx].flattenedRequests().first?.request.id
        }
        saveAPIStudio()
    }

    // MARK: - Environment CRUD

    @discardableResult
    func createAPIEnvironment(name: String = "New Environment") -> APIEnvironment {
        let env = APIEnvironment(
            name: name,
            variables: [APIEnvironmentVariable(key: "baseUrl", initialValue: "https://api.example.com")]
        )
        apiEnvironments.append(env)
        apiActiveEnvironmentID = env.id
        saveAPIStudio()
        return env
    }

    func updateAPIEnvironment(_ updated: APIEnvironment) {
        guard let idx = apiEnvironments.firstIndex(where: { $0.id == updated.id }) else { return }
        apiEnvironments[idx] = updated
        saveAPIStudio()
    }

    func duplicateAPIEnvironment(id: UUID) {
        guard let src = apiEnvironments.first(where: { $0.id == id }) else { return }
        let copy = APIEnvironment(
            id: UUID(),
            name: "\(src.name) Copy",
            sourceFormat: src.sourceFormat,
            variables: src.variables.map { v in
                var vc = v
                vc.id = UUID()
                return vc
            }
        )
        apiEnvironments.append(copy)
        apiActiveEnvironmentID = copy.id
        saveAPIStudio()
    }

    func deleteAPIEnvironment(id: UUID) {
        apiEnvironments.removeAll(where: { $0.id == id })
        if apiActiveEnvironmentID == id {
            apiActiveEnvironmentID = apiEnvironments.first?.id
        }
        saveAPIStudio()
    }

    // MARK: - Multi-Format Import & Export

    func presentImportAPIFilePanel() {
        let panel = NSOpenPanel()
        panel.title = "Import API Collection or Environment"
        panel.message = "Supports Postman v2.1/v2.0 JSON, Postman Environments, Insomnia v4 JSON, OpenAPI 3.x / Swagger 2.0 JSON, HAR 1.2, .http/.rest, .env, and cURL."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json, .plainText, .data]

        if panel.runModal() == .OK {
            importAPIFiles(urls: panel.urls)
        }
    }

    func importAPIFiles(urls: [URL]) {
        ensureAPIStudioLoaded()
        var importedCollections = 0
        var importedEnvs = 0
        var lastFormat: APISourceFormat?
        var errors: [String] = []

        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let outcome = try APIFormatCodec.importData(data, fileName: url.lastPathComponent)
                lastFormat = outcome.detectedFormat
                for col in outcome.collections {
                    apiCollections.append(col)
                    apiSelectedCollectionID = col.id
                    apiSelectedRequestID = col.flattenedRequests().first?.request.id
                    importedCollections += 1
                }
                for env in outcome.environments {
                    apiEnvironments.append(env)
                    if apiActiveEnvironmentID == nil || outcome.collections.isEmpty {
                        apiActiveEnvironmentID = env.id
                    }
                    importedEnvs += 1
                }
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if importedCollections > 0 || importedEnvs > 0 {
            saveAPIStudio()
            isAPIStudioVisible = true
            var parts: [String] = []
            if importedCollections > 0 { parts.append("\(importedCollections) collection(s)") }
            if importedEnvs > 0 { parts.append("\(importedEnvs) environment(s)") }
            let fmtLabel = lastFormat.map { " (\($0.displayName))" } ?? ""
            showBanner("Imported \(parts.joined(separator: " & "))\(fmtLabel)")
        }
        if !errors.isEmpty {
            showBanner(errors.joined(separator: " · "), isError: true)
        }
    }

    func importAPICurl(_ rawCurl: String, targetCollectionID: UUID?) {
        let parsed = APIFormatCodec.parseCurlCommands(rawCurl)
        guard !parsed.isEmpty else {
            showBanner("Could not parse a valid cURL command. Make sure it includes a URL.", isError: true)
            return
        }
        ensureAPIStudioLoaded()
        if let cid = targetCollectionID, let idx = apiCollections.firstIndex(where: { $0.id == cid }) {
            for req in parsed {
                apiCollections[idx].appendRequest(req, toFolderID: nil)
            }
            apiSelectedCollectionID = cid
            apiSelectedRequestID = parsed.first?.id
        } else {
            let col = APICollection(name: "Imported cURL", sourceFormat: .curl, requests: parsed)
            apiCollections.append(col)
            apiSelectedCollectionID = col.id
            apiSelectedRequestID = parsed.first?.id
        }
        saveAPIStudio()
        isAPIStudioVisible = true
        showBanner("Imported \(parsed.count) request(s) from cURL")
    }

    func exportAPICollection(_ collection: APICollection, format: APIExportCollectionFormat, redactSecrets: Bool = true) {
        let panel = NSSavePanel()
        panel.title = "Export \(collection.name) as \(format.rawValue)"
        panel.allowedContentTypes = [format.contentType]
        let safeStem = collection.name
            .replacingOccurrences(of: #"[^a-zA-Z0-9._-]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        panel.nameFieldStringValue = "\(safeStem.isEmpty ? "collection" : safeStem).\(format.fileExtension)"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            switch format {
            case .postmanV21:
                data = try APIFormatCodec.exportPostmanCollectionV21(collection)
            case .insomniaV4:
                data = try APIFormatCodec.exportInsomniaV4(collection: collection, environment: activeAPIEnvironment, redactSecrets: redactSecrets)
            case .httpFile:
                data = Data(APIFormatCodec.exportHTTPFile(collection).utf8)
            case .ceptraBundle:
                data = try APIFormatCodec.exportCeptraBundle(collections: [collection], environments: apiEnvironments, redactSecrets: redactSecrets)
            }
            try data.write(to: url, options: .atomic)
            showBanner("Exported \(collection.name) to \(url.lastPathComponent)")
        } catch {
            showBanner("Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    func exportAPIEnvironment(_ environment: APIEnvironment, format: APIExportEnvironmentFormat, redactSecrets: Bool = true) {
        let panel = NSSavePanel()
        panel.title = "Export \(environment.name) as \(format.rawValue)"
        panel.allowedContentTypes = [format.contentType]
        let safeStem = environment.name
            .replacingOccurrences(of: #"[^a-zA-Z0-9._-]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        panel.nameFieldStringValue = "\(safeStem.isEmpty ? "environment" : safeStem).\(format.fileExtension)"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            switch format {
            case .postmanEnvironment:
                data = try APIFormatCodec.exportPostmanEnvironment(environment, redactSecrets: redactSecrets)
            case .insomniaV4Environment:
                data = try APIFormatCodec.exportInsomniaV4(collection: nil, environment: environment, redactSecrets: redactSecrets)
            case .dotEnv:
                data = Data(APIFormatCodec.exportDotEnv(environment, redactSecrets: redactSecrets).utf8)
            }
            try data.write(to: url, options: .atomic)
            let redactNote = redactSecrets ? " (secrets redacted)" : ""
            showBanner("Exported \(environment.name) to \(url.lastPathComponent)\(redactNote)")
        } catch {
            showBanner("Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Single Request & Collection Execution

    func sendSelectedAPIRequest() {
        guard let ctx = selectedAPIRequestContext else { return }
        apiExecutionTask?.cancel()
        isAPIRunning = true
        apiCollectionRunProgress = nil
        let mergedVars = APIVariableResolver.mergedVariables(collection: ctx.collection, environment: activeAPIEnvironment)
        let req = ctx.request
        let auth = ctx.effectiveAuth
        let colID = ctx.collection.id
        let envID = apiActiveEnvironmentID
        let opts = apiRunOptions

        apiExecutionTask = Task { [weak self] in
            let result = await APIRequestRunner.execute(
                request: req,
                effectiveAuth: auth,
                variables: mergedVars,
                options: opts
            )
            guard let self, !Task.isCancelled else { return }
            self.apiLastResult = result
            self.apiExecutionHistory.insert(result, at: 0)
            if self.apiExecutionHistory.count > 40 {
                self.apiExecutionHistory.removeLast(self.apiExecutionHistory.count - 40)
            }
            self.applyExtractedVariables(
                from: req.extractors,
                values: result.extractedVariables,
                collectionID: colID,
                environmentID: envID
            )
            self.isAPIRunning = false
        }
    }

    func runAPICollection(collectionID: UUID, folderID: UUID? = nil) {
        guard let col = apiCollections.first(where: { $0.id == collectionID }) else { return }
        apiExecutionTask?.cancel()
        isAPIRunning = true
        apiCollectionRunSummary = nil
        apiCollectionRunProgress = (0, max(1, col.totalRequestCount))
        let activeEnv = activeAPIEnvironment
        let envID = activeEnv?.id
        let opts = apiRunOptions

        apiExecutionTask = Task { [weak self] in
            let weakSelf = self
            let outcome = await APIRequestRunner.runCollection(
                col,
                folderID: folderID,
                environment: activeEnv,
                options: opts,
                onProgress: { [weak weakSelf] completed, total, latest in
                    Task { @MainActor in
                        weakSelf?.apiCollectionRunProgress = (completed, total)
                        weakSelf?.apiLastResult = latest
                    }
                }
            )
            guard let self, !Task.isCancelled else { return }
            self.apiCollectionRunSummary = outcome.summary
            self.apiExecutionHistory.insert(contentsOf: outcome.summary.results.reversed(), at: 0)
            if self.apiExecutionHistory.count > 60 {
                self.apiExecutionHistory.removeLast(self.apiExecutionHistory.count - 60)
            }
            if let envID, !outcome.environmentUpdates.isEmpty,
               let eIdx = self.apiEnvironments.firstIndex(where: { $0.id == envID }) {
                for (k, v) in outcome.environmentUpdates {
                    self.apiEnvironments[eIdx].setVariable(key: k, value: v)
                }
            }
            if !outcome.collectionUpdates.isEmpty,
               let cIdx = self.apiCollections.firstIndex(where: { $0.id == collectionID }) {
                for (k, v) in outcome.collectionUpdates {
                    self.apiCollections[cIdx].setVariable(key: k, value: v)
                }
            }
            if !outcome.environmentUpdates.isEmpty || !outcome.collectionUpdates.isEmpty {
                self.saveAPIStudio()
            }
            self.isAPIRunning = false
            self.apiCollectionRunProgress = nil
            self.showBanner("Ran \(outcome.summary.collectionName): \(outcome.summary.passedCount) passed, \(outcome.summary.failedCount) failed (\(outcome.summary.totalDurationMs)ms)", isError: outcome.summary.failedCount > 0)
        }
    }

    func cancelAPIExecution() {
        apiExecutionTask?.cancel()
        apiExecutionTask = nil
        isAPIRunning = false
        apiCollectionRunProgress = nil
    }

    private func applyExtractedVariables(
        from extractors: [APIVariableExtractor],
        values: [String: String],
        collectionID: UUID,
        environmentID: UUID?
    ) {
        guard !values.isEmpty else { return }
        var changed = false
        for ext in extractors where ext.isEnabled {
            let key = ext.targetVariableName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let val = values[key] else { continue }
            switch ext.scope {
            case .environment:
                if let envID = environmentID, let idx = apiEnvironments.firstIndex(where: { $0.id == envID }) {
                    apiEnvironments[idx].setVariable(key: key, value: val)
                    changed = true
                }
            case .collection:
                if let idx = apiCollections.firstIndex(where: { $0.id == collectionID }) {
                    apiCollections[idx].setVariable(key: key, value: val)
                    changed = true
                }
            }
        }
        if changed {
            saveAPIStudio()
        }
    }

    // MARK: - Replay HTML & Automated Test Suite Bridge

    func openAPICollectionRunInReplay(_ summary: APICollectionRunSummary) {
        let projectPath = workspace?.rootURL.path ?? NSHomeDirectory()
        let projectName = workspace?.config.projectName ?? "API Studio"
        let (report, bundle) = summary.toTimeTravelReport(projectPath: projectPath, projectName: projectName)
        recordSyntheticAPIReplay(report: report, bundle: bundle)
    }

    func exportAPICollectionRunReplayHTML(_ summary: APICollectionRunSummary) {
        let projectPath = workspace?.rootURL.path ?? NSHomeDirectory()
        let projectName = workspace?.config.projectName ?? "API Studio"
        let (report, bundle) = summary.toTimeTravelReport(projectPath: projectPath, projectName: projectName)
        let html = TimeTravelHTMLReportBuilder.build(report, traceBundle: bundle)

        let panel = NSSavePanel()
        panel.title = "Export API Collection Replay HTML Report"
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "ceptra-api-replay.html"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(url)
                showBanner("Exported interactive Replay HTML to \(url.lastPathComponent)")
            } catch {
                showBanner("Failed to export Replay HTML: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func generateAutomatedTestSuiteFile(from collection: APICollection) {
        let framework = activeFramework
        let generated = APICodeGenerator.generateTestFile(
            for: collection,
            environment: activeAPIEnvironment,
            framework: framework
        )

        let panel = NSSavePanel()
        panel.title = "Generate \(framework.displayName) API Test File"
        panel.nameFieldStringValue = generated.suggestedFileName
        panel.canCreateDirectories = true
        if let root = workspace?.rootURL {
            let testsDir = root.appendingPathComponent("tests", isDirectory: true)
            panel.directoryURL = FileManager.default.fileExists(atPath: testsDir.path) ? testsDir : root
        }

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try generated.content.write(to: url, atomically: true, encoding: .utf8)
                rescanWorkspace()
                isAPIStudioVisible = false
                openFileByURL(url)
                showBanner("Generated \(url.lastPathComponent) for \(framework.displayName)")
            } catch {
                showBanner("Could not write test file: \(error.localizedDescription)", isError: true)
            }
        }
    }
}
