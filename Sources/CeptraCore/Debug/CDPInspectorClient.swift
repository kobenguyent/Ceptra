import Foundation

public enum CDPInspectorError: LocalizedError, Sendable {
    case invalidLoopbackURL(String)
    case notConnected
    case protocolError(code: Int, message: String)
    case invalidResponse
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .invalidLoopbackURL(let raw):
            return "Refused non-loopback inspector URL: \(raw)"
        case .notConnected:
            return "Debugger is not connected."
        case .protocolError(_, let message):
            return "Inspector error: \(message)"
        case .invalidResponse:
            return "Unexpected inspector response payload."
        case .disconnected:
            return "Debugger connection closed."
        }
    }
}

public enum CDPEvent: Sendable {
    case scriptParsed(scriptId: String, url: String, sourceMapURL: String?)
    case paused(reason: String, callFrames: [DebugCallFrame], hitBreakpointIDs: [String])
    case resumed
    case disconnected(String?)
}

/// Zero-dependency Chrome DevTools Protocol (V8 Inspector) client built on `URLSessionWebSocketTask`.
/// Supports loopback-only Node.js `--inspect-brk=127.0.0.1:0` debugging, inline SourceMap v3
/// translation (for CodeceptJS 4.x `.temp.mjs`), breakpoints, stepping, scopes, and eval.
public actor CDPInspectorClient {
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    private var nextRequestID: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    private var eventContinuation: AsyncStream<CDPEvent>.Continuation?
    public nonisolated let events: AsyncStream<CDPEvent>

    // Script & SourceMap registries
    private var scriptURLsByID: [String: String] = [:]
    private var sourceMapsByScriptID: [String: SourceMapV3] = [:]

    // Active CDP breakpoint IDs keyed by DebugBreakpoint.id (a single TS breakpoint can map to 1+ CDP IDs)
    private var cdpBreakpointIDsByLocalID: [UUID: [String]] = [:]
    private var desiredBreakpoints: [UUID: DebugBreakpoint] = [:]

    public init() {
        var captured: AsyncStream<CDPEvent>.Continuation?
        self.events = AsyncStream<CDPEvent> { continuation in
            captured = continuation
        }
        self.eventContinuation = captured
    }

    public static func validateLoopbackInspectorURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "ws" else { return false }
        guard let host = url.host?.lowercased(), host == "127.0.0.1" || host == "localhost" else { return false }
        return url.port != nil
    }

    public func connect(to url: URL) async throws {
        guard Self.validateLoopbackInspectorURL(url) else {
            throw CDPInspectorError.invalidLoopbackURL(url.absoluteString)
        }
        disconnect()

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let urlSession = URLSession(configuration: config)
        let task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 32 * 1024 * 1024
        self.session = urlSession
        self.webSocketTask = task
        task.resume()

        self.receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil

        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, cont) in pending {
            cont.resume(throwing: CDPInspectorError.disconnected)
        }

        scriptURLsByID.removeAll()
        sourceMapsByScriptID.removeAll()
        cdpBreakpointIDsByLocalID.removeAll()
    }

    public func enableDebugger(
        breakpoints: [DebugBreakpoint],
        exceptionMode: ExceptionBreakMode
    ) async throws {
        _ = try await send(method: "Runtime.enable")
        _ = try await send(method: "Debugger.enable")
        _ = try? await send(method: "Debugger.setAsyncCallStackDepth", params: ["maxDepth": 32])
        try await setPauseOnExceptions(exceptionMode)

        desiredBreakpoints = Dictionary(uniqueKeysWithValues: breakpoints.map { ($0.id, $0) })
        for bp in breakpoints where bp.isEnabled {
            try? await registerBreakpoint(bp)
        }

        _ = try await send(method: "Runtime.runIfWaitingForDebugger")
    }

    public func setPauseOnExceptions(_ mode: ExceptionBreakMode) async throws {
        _ = try await send(method: "Debugger.setPauseOnExceptions", params: ["state": mode.rawValue])
    }

    public func syncBreakpoint(_ breakpoint: DebugBreakpoint) async {
        desiredBreakpoints[breakpoint.id] = breakpoint
        await unregisterBreakpoint(id: breakpoint.id)
        if breakpoint.isEnabled {
            try? await registerBreakpoint(breakpoint)
        }
    }

    public func removeBreakpoint(id: UUID) async {
        desiredBreakpoints.removeValue(forKey: id)
        await unregisterBreakpoint(id: id)
    }

    public func resume() async throws {
        _ = try await send(method: "Debugger.resume")
    }

    public func pause() async throws {
        _ = try await send(method: "Debugger.pause")
    }

    public func stepOver() async throws {
        _ = try await send(method: "Debugger.stepOver")
    }

    public func stepInto() async throws {
        _ = try await send(method: "Debugger.stepInto")
    }

    public func stepOut() async throws {
        _ = try await send(method: "Debugger.stepOut")
    }

    public func getProperties(objectId: String) async throws -> [DebugVariable] {
        let result = try await send(
            method: "Runtime.getProperties",
            params: [
                "objectId": objectId,
                "ownProperties": true,
                "accessorPropertiesOnly": false,
                "generatePreview": true
            ]
        )
        let rawList = result["result"] as? [[String: Any]] ?? []
        var variables: [DebugVariable] = []
        variables.reserveCapacity(rawList.count)

        for item in rawList {
            guard let name = item["name"] as? String else { continue }
            if name == "__proto__" { continue }
            if let valueObj = item["value"] as? [String: Any] {
                variables.append(Self.parseVariable(name: name, remoteObject: valueObj))
            } else if item["get"] != nil {
                variables.append(DebugVariable(name: name, value: "(getter)", type: "accessor"))
            }
        }
        return variables.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func evaluateOnCallFrame(callFrameId: String, expression: String) async throws -> DebugEvalResult {
        let result = try await send(
            method: "Debugger.evaluateOnCallFrame",
            params: [
                "callFrameId": callFrameId,
                "expression": expression,
                "includeCommandLineAPI": true,
                "silent": true,
                "returnByValue": false,
                "generatePreview": true
            ]
        )
        return Self.parseEvalResult(expression: expression, response: result)
    }

    public func evaluate(expression: String) async throws -> DebugEvalResult {
        let result = try await send(
            method: "Runtime.evaluate",
            params: [
                "expression": expression,
                "includeCommandLineAPI": true,
                "silent": true,
                "returnByValue": false,
                "generatePreview": true
            ]
        )
        return Self.parseEvalResult(expression: expression, response: result)
    }

    // MARK: - Breakpoint Registration

    private func registerBreakpoint(_ bp: DebugBreakpoint) async throws {
        var ids: [String] = []
        let resolvedPath = URL(fileURLWithPath: bp.filePath).resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalNoPrivate = resolvedPath.hasPrefix("/private/") ? String(resolvedPath.dropFirst("/private".count)) : resolvedPath
        let escapedPath = CommandBuilder.escapeRegExp(canonicalNoPrivate)
        // Match `file:///path`, `/path`, and macOS `/private/var` vs `/var` symlinks in V8 Inspector
        let urlRegex = "^(file://)?(/private)?\(escapedPath)$"

        // 1. Register direct URL-regex breakpoint (covers .js CJS, .mjs ESM, .cjs, and native Node .ts)
        var params: [String: Any] = [
            "lineNumber": max(0, bp.line - 1),
            "urlRegex": urlRegex,
            "columnNumber": 0
        ]
        if let cond = bp.effectiveCDPCondition {
            params["condition"] = cond
        }
        if let resp = try? await send(method: "Debugger.setBreakpointByUrl", params: params),
           let cdpID = resp["breakpointId"] as? String {
            ids.append(cdpID)
        }

        // 2. Also bind against any already-parsed transpiled scripts (e.g. CodeceptJS .temp.mjs)
        for (scriptId, sourceMap) in sourceMapsByScriptID {
            if let gen = sourceMap.generatedPosition(forOriginalFile: bp.filePath, oneBasedLine: bp.line) {
                var locParams: [String: Any] = [
                    "location": [
                        "scriptId": scriptId,
                        "lineNumber": gen.line,
                        "columnNumber": gen.column
                    ]
                ]
                if let cond = bp.effectiveCDPCondition {
                    locParams["condition"] = cond
                }
                if let resp = try? await send(method: "Debugger.setBreakpoint", params: locParams),
                   let cdpID = resp["breakpointId"] as? String {
                    ids.append(cdpID)
                }
            }
        }

        cdpBreakpointIDsByLocalID[bp.id] = ids
    }

    private func unregisterBreakpoint(id: UUID) async {
        guard let ids = cdpBreakpointIDsByLocalID.removeValue(forKey: id) else { return }
        for cdpID in ids {
            _ = try? await send(method: "Debugger.removeBreakpoint", params: ["breakpointId": cdpID])
        }
    }

    private func bindBreakpointsForNewSourceMap(scriptId: String, sourceMap: SourceMapV3) async {
        for bp in desiredBreakpoints.values where bp.isEnabled {
            guard let gen = sourceMap.generatedPosition(forOriginalFile: bp.filePath, oneBasedLine: bp.line) else {
                continue
            }
            var locParams: [String: Any] = [
                "location": [
                    "scriptId": scriptId,
                    "lineNumber": gen.line,
                    "columnNumber": gen.column
                ]
            ]
            if let cond = bp.effectiveCDPCondition {
                locParams["condition"] = cond
            }
            if let resp = try? await send(method: "Debugger.setBreakpoint", params: locParams),
               let cdpID = resp["breakpointId"] as? String {
                cdpBreakpointIDsByLocalID[bp.id, default: []].append(cdpID)
            }
        }
    }

    // MARK: - Low-Level JSON-RPC Transport

    private func send(method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        guard let webSocketTask else {
            throw CDPInspectorError.notConnected
        }

        let requestID = nextRequestID
        nextRequestID += 1

        var payload: [String: Any] = [
            "id": requestID,
            "method": method
        ]
        if let params {
            payload["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CDPInspectorError.invalidResponse
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            webSocketTask.send(.string(text)) { [weak self] error in
                if let error {
                    Task { await self?.failRequest(id: requestID, error: error) }
                }
            }
        }
    }

    private func failRequest(id: Int, error: Error) {
        if let cont = pendingRequests.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let task = webSocketTask else { break }
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let raw):
                    data = raw
                @unknown default:
                    continue
                }
                await handleIncomingData(data)
            } catch {
                if !Task.isCancelled {
                    let pending = pendingRequests
                    pendingRequests.removeAll()
                    for (_, cont) in pending {
                        cont.resume(throwing: CDPInspectorError.disconnected)
                    }
                    eventContinuation?.yield(.disconnected(error.localizedDescription))
                }
                break
            }
        }
    }

    private func handleIncomingData(_ data: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Response to a pending RPC request
        if let id = json["id"] as? Int {
            guard let cont = pendingRequests.removeValue(forKey: id) else { return }
            if let errorObj = json["error"] as? [String: Any] {
                let code = errorObj["code"] as? Int ?? -1
                let msg = errorObj["message"] as? String ?? "Unknown CDP error"
                cont.resume(throwing: CDPInspectorError.protocolError(code: code, message: msg))
            } else {
                let result = json["result"] as? [String: Any] ?? [:]
                cont.resume(returning: result)
            }
            return
        }

        // Asynchronous CDP event notification
        guard let method = json["method"] as? String else { return }
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "Debugger.scriptParsed":
            guard let scriptId = params["scriptId"] as? String else { return }
            let url = params["url"] as? String ?? ""
            let sourceMapURL = (params["sourceMapURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if !url.isEmpty {
                scriptURLsByID[scriptId] = url
            }
            if let sourceMapURL, let map = SourceMapV3.decode(sourceMapURL: sourceMapURL, scriptURLString: url) {
                sourceMapsByScriptID[scriptId] = map
                Task { [weak self] in
                    await self?.bindBreakpointsForNewSourceMap(scriptId: scriptId, sourceMap: map)
                }
            }
            eventContinuation?.yield(.scriptParsed(scriptId: scriptId, url: url, sourceMapURL: sourceMapURL))

        case "Debugger.paused":
            let reason = params["reason"] as? String ?? "other"
            let hitBreakpoints = params["hitBreakpoints"] as? [String] ?? []
            let rawFrames = params["callFrames"] as? [[String: Any]] ?? []
            let parsedFrames = rawFrames.compactMap { parseCallFrame($0) }
            eventContinuation?.yield(.paused(reason: reason, callFrames: parsedFrames, hitBreakpointIDs: hitBreakpoints))

        case "Debugger.resumed":
            eventContinuation?.yield(.resumed)

        default:
            break
        }
    }

    // MARK: - Payload Parsing Helpers

    private func parseCallFrame(_ raw: [String: Any]) -> DebugCallFrame? {
        guard let callFrameId = raw["callFrameId"] as? String,
              let loc = raw["location"] as? [String: Any],
              let scriptId = loc["scriptId"] as? String else {
            return nil
        }
        let genLine = loc["lineNumber"] as? Int ?? 0
        let genCol = loc["columnNumber"] as? Int ?? 0
        let fnName = raw["functionName"] as? String ?? ""

        let rawURL = (raw["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? scriptURLsByID[scriptId] ?? ""
        let location: DebugSourceLocation

        if let sourceMap = sourceMapsByScriptID[scriptId],
           let mapped = sourceMap.originalPosition(generatedLine: genLine, generatedColumn: genCol) {
            location = DebugSourceLocation(
                filePath: mapped.sourcePath,
                line: mapped.line,
                column: mapped.column,
                scriptId: scriptId
            )
        } else {
            let filePath: String
            if rawURL.hasPrefix("file://"), let fileURL = URL(string: rawURL) {
                filePath = fileURL.standardizedFileURL.path
            } else {
                filePath = rawURL
            }
            location = DebugSourceLocation(
                filePath: filePath,
                line: genLine + 1,
                column: genCol + 1,
                scriptId: scriptId
            )
        }

        let rawScopes = raw["scopeChain"] as? [[String: Any]] ?? []
        var scopes: [DebugScope] = []
        for s in rawScopes {
            guard let scopeType = s["type"] as? String,
                  let obj = s["object"] as? [String: Any],
                  let objectId = obj["objectId"] as? String else {
                continue
            }
            if scopeType == "global" { continue } // Keep inspector focused on local/closure/block/script scopes
            scopes.append(DebugScope(type: scopeType, name: s["name"] as? String, objectId: objectId))
        }

        let thisObjectId = (raw["this"] as? [String: Any])?["objectId"] as? String
        let isInternal = location.filePath.isEmpty
            || location.filePath.hasPrefix("node:")
            || location.filePath.contains("/node_modules/")

        return DebugCallFrame(
            id: callFrameId,
            functionName: fnName,
            location: location,
            scopes: scopes,
            thisObjectId: thisObjectId,
            isInternal: isInternal
        )
    }

    private static func parseVariable(name: String, remoteObject: [String: Any]) -> DebugVariable {
        let type = remoteObject["type"] as? String ?? "undefined"
        let subtype = remoteObject["subtype"] as? String
        let className = remoteObject["className"] as? String
        let objectId = remoteObject["objectId"] as? String
        let value = formatRemoteObject(remoteObject)
        return DebugVariable(
            name: name,
            value: value,
            type: type,
            subtype: subtype,
            className: className,
            objectId: objectId
        )
    }

    private static func parseEvalResult(expression: String, response: [String: Any]) -> DebugEvalResult {
        if let exceptionDetails = response["exceptionDetails"] as? [String: Any] {
            let exObj = exceptionDetails["exception"] as? [String: Any]
            let text = exObj.map { formatRemoteObject($0) }
                ?? (exceptionDetails["text"] as? String)
                ?? "Evaluation error"
            return DebugEvalResult(expression: expression, value: text, type: "error", isError: true)
        }
        let resultObj = response["result"] as? [String: Any] ?? [:]
        let type = resultObj["type"] as? String ?? "undefined"
        let objectId = resultObj["objectId"] as? String
        return DebugEvalResult(
            expression: expression,
            value: formatRemoteObject(resultObj),
            type: type,
            isError: false,
            objectId: objectId
        )
    }

    public static func formatRemoteObject(_ obj: [String: Any]) -> String {
        let type = obj["type"] as? String ?? "undefined"
        let subtype = obj["subtype"] as? String

        if subtype == "null" { return "null" }
        if type == "undefined" { return "undefined" }

        if type == "string" {
            let raw = obj["value"] as? String ?? ""
            let truncated = raw.count > 120 ? String(raw.prefix(120)) + "…" : raw
            return "\"\(truncated)\""
        }

        if let desc = obj["description"] as? String, !desc.isEmpty {
            if let preview = obj["preview"] as? [String: Any],
               let props = preview["properties"] as? [[String: Any]], !props.isEmpty {
                let rendered = props.prefix(4).compactMap { p -> String? in
                    guard let k = p["name"] as? String else { return nil }
                    let v = p["value"] as? String ?? (p["type"] as? String ?? "")
                    return subtype == "array" ? v : "\(k): \(v)"
                }.joined(separator: ", ")
                let overflow = (preview["overflow"] as? Bool == true) ? ", …" : ""
                if subtype == "array" {
                    return "\(desc) [\(rendered)\(overflow)]"
                }
                return "\(desc) { \(rendered)\(overflow) }"
            }
            return desc
        }

        if let val = obj["value"] {
            return String(describing: val)
        }
        return type
    }
}
