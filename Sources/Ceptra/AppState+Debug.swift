import CeptraCore
import Foundation

@MainActor
extension AppState {
    // MARK: - Computed Debug Helpers

    var selectedCallFrame: DebugCallFrame? {
        if let id = selectedCallFrameID, let match = debugCallFrames.first(where: { $0.id == id }) {
            return match
        }
        return visibleCallFrames.first ?? debugCallFrames.first
    }

    var visibleCallFrames: [DebugCallFrame] {
        if debugJustMyCode {
            let userFrames = debugCallFrames.filter { !$0.isInternal }
            return userFrames.isEmpty ? debugCallFrames : userFrames
        }
        return debugCallFrames
    }

    var pausedLocation: DebugSourceLocation? {
        guard debugPhase.isPaused else { return nil }
        return selectedCallFrame?.location
    }

    func activePausedLine(forFilePath filePath: String) -> Int? {
        guard let loc = pausedLocation else { return nil }
        let normalizedTarget = URL(fileURLWithPath: filePath).standardizedFileURL.path
        let normalizedPaused = URL(fileURLWithPath: loc.filePath).standardizedFileURL.path
        return normalizedTarget == normalizedPaused ? loc.line : nil
    }

    func breakpointsByLine(forFilePath filePath: String) -> [Int: DebugBreakpoint] {
        let normalized = URL(fileURLWithPath: filePath).standardizedFileURL.path
        var map: [Int: DebugBreakpoint] = [:]
        for bp in breakpoints where bp.filePath == normalized {
            map[bp.line] = bp
        }
        return map
    }

    // MARK: - Persistence

    func loadDebugStateForWorkspace(rootPath: String) {
        breakpoints = breakpointStore.loadBreakpoints(forWorkspaceRoot: rootPath)
        let savedExprs = breakpointStore.loadWatchExpressions(forWorkspaceRoot: rootPath)
        debugWatchItems = savedExprs.map { DebugWatchItem(expression: $0) }
    }

    private func persistBreakpoints() {
        guard let root = workspace?.rootURL.path else { return }
        breakpointStore.saveBreakpoints(breakpoints, forWorkspaceRoot: root)
    }

    private func persistWatchExpressions() {
        guard let root = workspace?.rootURL.path else { return }
        breakpointStore.saveWatchExpressions(debugWatchItems.map(\.expression), forWorkspaceRoot: root)
    }

    // MARK: - Breakpoint Management

    func toggleBreakpoint(filePath: String, line: Int) {
        let normalized = URL(fileURLWithPath: filePath).standardizedFileURL.path
        if let existingIdx = breakpoints.firstIndex(where: { $0.filePath == normalized && $0.line == line }) {
            let removed = breakpoints.remove(at: existingIdx)
            persistBreakpoints()
            if let client = cdpClient {
                Task { await client.removeBreakpoint(id: removed.id) }
            }
        } else {
            let bp = DebugBreakpoint(filePath: normalized, line: line)
            breakpoints.append(bp)
            sortBreakpoints()
            persistBreakpoints()
            if let client = cdpClient {
                Task { await client.syncBreakpoint(bp) }
            }
        }
    }

    func updateBreakpoint(_ updated: DebugBreakpoint) {
        if let idx = breakpoints.firstIndex(where: { $0.id == updated.id }) {
            breakpoints[idx] = updated
        } else {
            breakpoints.append(updated)
        }
        sortBreakpoints()
        persistBreakpoints()
        if let client = cdpClient {
            Task { await client.syncBreakpoint(updated) }
        }
    }

    func toggleBreakpointEnabled(id: UUID) {
        guard let idx = breakpoints.firstIndex(where: { $0.id == id }) else { return }
        breakpoints[idx].isEnabled.toggle()
        let bp = breakpoints[idx]
        persistBreakpoints()
        if let client = cdpClient {
            Task { await client.syncBreakpoint(bp) }
        }
    }

    func removeBreakpoint(id: UUID) {
        breakpoints.removeAll { $0.id == id }
        persistBreakpoints()
        if let client = cdpClient {
            Task { await client.removeBreakpoint(id: id) }
        }
    }

    func clearAllBreakpoints() {
        let existing = breakpoints
        breakpoints = []
        persistBreakpoints()
        if let client = cdpClient {
            Task {
                for bp in existing {
                    await client.removeBreakpoint(id: bp.id)
                }
            }
        }
    }

    private func sortBreakpoints() {
        breakpoints.sort {
            if $0.filePath == $1.filePath { return $0.line < $1.line }
            return $0.filePath < $1.filePath
        }
    }

    // MARK: - Launch Debug Sessions

    func debug(mode: CodeceptRunMode) {
        var opts = runOptions.debugLaunchOptions
        opts.enabled = true
        run(mode: mode, debugLaunch: opts)
    }

    func debugActiveFile() {
        guard isActiveTabExecutableTestFile, let tab = activeTab else {
            showBanner("Select a CodeceptJS test file containing Feature() or Scenario() to debug.", isError: true)
            return
        }
        let targetRel = activeWorkspaceFile?.relativePath ?? tab.relativePath
        debug(mode: .runFile(relativePath: targetRel))
    }

    func restartDebugSession() {
        let modeToRun = lastDebugMode ?? (isActiveTabExecutableTestFile && activeTab != nil
            ? .runFile(relativePath: activeWorkspaceFile?.relativePath ?? activeTab!.relativePath)
            : .runAll)
        if isRunning {
            stopActiveRun()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.debug(mode: modeToRun)
            }
        } else {
            debug(mode: modeToRun)
        }
    }

    func setExceptionBreakMode(_ mode: ExceptionBreakMode) {
        runOptions.debugLaunchOptions.breakOnExceptions = mode
        saveSettings()
        if let client = cdpClient {
            Task { try? await client.setPauseOnExceptions(mode) }
        }
    }

    // MARK: - CDP Attach & Lifecycle

    func attachInspector(to url: URL) {
        let client = CDPInspectorClient()
        self.cdpClient = client
        let initialBreakpoints = self.breakpoints
        let exceptionMode = self.runOptions.debugLaunchOptions.breakOnExceptions

        cdpEventTask?.cancel()
        cdpEventTask = Task { [weak self] in
            for await event in client.events {
                guard let self else { break }
                self.handleCDPEvent(event)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.connect(to: url)
                try await client.enableDebugger(breakpoints: initialBreakpoints, exceptionMode: exceptionMode)
                if self.debugPhase == .launching {
                    self.debugPhase = .running
                }
            } catch {
                self.consoleLogs.append(ConsoleLogEntry(
                    timestamp: Date(),
                    text: "[Debugger] Attach error: \(error.localizedDescription)",
                    isError: true,
                    isStep: false,
                    isHighlight: false
                ))
            }
        }
    }

    func handleCDPEvent(_ event: CDPEvent) {
        switch event {
        case .scriptParsed:
            break

        case .paused(let reason, let callFrames, let hitBreakpointIDs):
            // Auto-continue past Node's initial `--inspect-brk` bootstrap pause
            if !hasHandledInitialBreakOnStart && hitBreakpointIDs.isEmpty && (reason == "Break on start" || reason == "other") {
                if let top = callFrames.first, top.isInternal || top.location.filePath.contains("/codeceptjs/") {
                    hasHandledInitialBreakOnStart = true
                    debugContinue()
                    return
                }
            }
            hasHandledInitialBreakOnStart = true
            debugPhase = .paused(reason: reason)
            debugCallFrames = callFrames
            debugScopeVariables = [:]
            isDebugInspectorVisible = true

            if let preferred = visibleCallFrames.first ?? callFrames.first {
                selectCallFrame(preferred)
            }

        case .resumed:
            if debugPhase.isPaused {
                debugPhase = .running
            }
            debugCallFrames = []
            selectedCallFrameID = nil
            debugScopeVariables = [:]

        case .disconnected:
            if debugPhase.isActive && !isRunning {
                cleanupDebugSession()
            }
        }
    }

    func cleanupDebugSession() {
        cdpEventTask?.cancel()
        cdpEventTask = nil
        if let client = cdpClient {
            cdpClient = nil
            Task { await client.disconnect() }
        }
        debugPhase = .idle
        debugCallFrames = []
        selectedCallFrameID = nil
        debugScopeVariables = [:]
        isInteractivePauseShellActive = false
        hasHandledInitialBreakOnStart = false
    }

    // MARK: - Step Controls

    func debugContinue() {
        guard let client = cdpClient else { return }
        Task { try? await client.resume() }
    }

    func debugPause() {
        guard let client = cdpClient else { return }
        Task { try? await client.pause() }
    }

    func debugStepOver() {
        guard let client = cdpClient else { return }
        Task { try? await client.stepOver() }
    }

    func debugStepInto() {
        guard let client = cdpClient else { return }
        Task { try? await client.stepInto() }
    }

    func debugStepOut() {
        guard let client = cdpClient else { return }
        Task { try? await client.stepOut() }
    }

    // MARK: - Frame, Scope, Watch & Eval Inspection

    func selectCallFrame(_ frame: DebugCallFrame) {
        selectedCallFrameID = frame.id
        if !frame.location.filePath.isEmpty && FileManager.default.fileExists(atPath: frame.location.filePath) {
            let fileURL = URL(fileURLWithPath: frame.location.filePath)
            openFileByURL(fileURL, jumpToLine: frame.location.line)
        }
        loadScopes(for: frame)
        refreshWatchExpressions()
    }

    private func loadScopes(for frame: DebugCallFrame) {
        guard let client = cdpClient else { return }
        let objectIds = frame.scopes.map(\.objectId) + (frame.thisObjectId.map { [$0] } ?? [])
        Task { [weak self] in
            for objId in objectIds {
                if let vars = try? await client.getProperties(objectId: objId) {
                    self?.debugScopeVariables[objId] = vars
                }
            }
        }
    }

    func loadVariables(forObjectId objectId: String) {
        guard let client = cdpClient else { return }
        if debugScopeVariables[objectId] != nil { return }
        Task { [weak self] in
            if let vars = try? await client.getProperties(objectId: objectId) {
                self?.debugScopeVariables[objectId] = vars
            }
        }
    }

    func addWatchExpression(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        debugWatchItems.append(DebugWatchItem(expression: trimmed))
        persistWatchExpressions()
        refreshWatchExpressions()
    }

    func removeWatchItem(id: UUID) {
        debugWatchItems.removeAll { $0.id == id }
        persistWatchExpressions()
    }

    func refreshWatchExpressions() {
        guard let client = cdpClient, debugPhase.isPaused, let frameId = selectedCallFrame?.id else {
            return
        }
        let items = debugWatchItems
        Task { [weak self] in
            for item in items {
                if let eval = try? await client.evaluateOnCallFrame(callFrameId: frameId, expression: item.expression) {
                    guard let self, let idx = self.debugWatchItems.firstIndex(where: { $0.id == item.id }) else { continue }
                    self.debugWatchItems[idx].value = eval.value
                    self.debugWatchItems[idx].type = eval.type
                    self.debugWatchItems[idx].isError = eval.isError
                    self.debugWatchItems[idx].objectId = eval.objectId
                }
            }
        }
    }

    func evaluateDebugExpression(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = cdpClient else { return }
        let frameId = debugPhase.isPaused ? selectedCallFrame?.id : nil
        Task { [weak self] in
            let eval: DebugEvalResult
            do {
                if let frameId {
                    eval = try await client.evaluateOnCallFrame(callFrameId: frameId, expression: trimmed)
                } else {
                    eval = try await client.evaluate(expression: trimmed)
                }
            } catch {
                eval = DebugEvalResult(expression: trimmed, value: error.localizedDescription, type: "error", isError: true)
            }
            self?.debugConsoleEntries.append(DebugConsoleEntry(
                expression: trimmed,
                result: eval.value,
                isError: eval.isError
            ))
            if let count = self?.debugConsoleEntries.count, count > 200 {
                self?.debugConsoleEntries.removeFirst(50)
            }
        }
    }

    // MARK: - CodeceptJS Interactive `pause()` Shell

    func sendInteractiveShellCommand(_ raw: String) {
        let display = raw.isEmpty ? "↵ (next step)" : raw
        let sent = runnerService.sendStdin(raw + "\n")
        consoleLogs.append(ConsoleLogEntry(
            timestamp: Date(),
            text: "I.> \(display)",
            isError: !sent,
            isStep: false,
            isHighlight: true
        ))
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "exit" ||
           raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "resume" {
            isInteractivePauseShellActive = false
            if debugPhase == .interactiveShell {
                debugPhase = .running
            }
        }
    }
}
