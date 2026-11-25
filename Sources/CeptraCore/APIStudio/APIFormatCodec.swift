import Foundation

public enum APIFormatCodecError: LocalizedError, Sendable {
    case unsupportedFormat(String)
    case invalidJSON(String)
    case emptyInput

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let detail):
            return "Unsupported API format: \(detail)"
        case .invalidJSON(let detail):
            return "Could not parse JSON: \(detail)"
        case .emptyInput:
            return "Input file or text is empty."
        }
    }
}

/// Clean-room, zero-dependency importer and exporter for open API interchange formats:
/// Postman Collection v2.1/v2.0, Postman Environment/Globals, Insomnia v4 JSON,
/// OpenAPI 3.x / Swagger 2.0 JSON, HAR 1.2 JSON, `.http`/`.rest` files, cURL, and `.env`.
public enum APIFormatCodec {

    // MARK: - Auto-Detecting Import

    public static func importData(_ data: Data, fileName: String? = nil) throws -> APIImportOutcome {
        guard !data.isEmpty else { throw APIFormatCodecError.emptyInput }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIFormatCodecError.emptyInput }

        // 1. Try JSON-based formats first
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let obj: Any
            do {
                obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            } catch {
                throw APIFormatCodecError.invalidJSON(error.localizedDescription)
            }

            if let dict = obj as? [String: Any] {
                // a) Ceptra native workspace bundle
                if dict["collections"] is [Any] && dict["environments"] is [Any] && dict["version"] is Int {
                    let dec = JSONDecoder()
                    dec.dateDecodingStrategy = .iso8601
                    if let bundle = try? dec.decode(APIStudioWorkspaceData.self, from: data) {
                        return APIImportOutcome(
                            detectedFormat: .ceptra,
                            collections: bundle.collections,
                            environments: bundle.environments
                        )
                    }
                }

                // b) Insomnia v4 Export (`_type == "export"` and `resources` array)
                if (dict["_type"] as? String) == "export" || (dict["__export_format"] != nil && dict["resources"] is [Any]) {
                    return try importInsomniaV4(dict, fileName: fileName)
                }

                // c) Postman Environment / Globals
                if let scope = (dict["_postman_variable_scope"] as? String)?.lowercased(),
                   scope == "environment" || scope == "globals" {
                    return importPostmanEnvironment(dict, fileName: fileName)
                }
                if dict["values"] is [[String: Any]], dict["item"] == nil, dict["info"] == nil, dict["paths"] == nil {
                    return importPostmanEnvironment(dict, fileName: fileName)
                }

                // d) Postman Collection v2.1 / v2.0
                if let info = dict["info"] as? [String: Any],
                   ((info["schema"] as? String)?.lowercased().contains("getpostman.com") == true || dict["item"] is [Any]) {
                    return importPostmanCollection(dict, fileName: fileName)
                }

                // e) OpenAPI 3.x / Swagger 2.0
                if dict["openapi"] is String || dict["swagger"] is String, dict["paths"] is [String: Any] {
                    return importOpenAPI(dict, fileName: fileName)
                }

                // f) HAR 1.2
                if let log = dict["log"] as? [String: Any], log["entries"] is [Any] {
                    return importHAR(log, fileName: fileName)
                }
            }

            throw APIFormatCodecError.unsupportedFormat(
                "JSON file did not match Postman v2.1, Postman Environment, Insomnia v4, OpenAPI 3.x/2.0, HAR 1.2, or Ceptra bundle."
            )
        }

        // 2. Try cURL command(s)
        let lowerName = (fileName ?? "").lowercased()
        if trimmed.lowercased().hasPrefix("curl ") || trimmed.lowercased().contains("\ncurl ") {
            let requests = parseCurlCommands(trimmed)
            if !requests.isEmpty {
                let colName = fileName.map { ($0 as NSString).deletingPathExtension } ?? "Imported cURL"
                let col = APICollection(name: colName, sourceFormat: .curl, requests: requests)
                return APIImportOutcome(detectedFormat: .curl, collections: [col])
            }
        }

        // 3. Try .http / .rest format (VS Code REST Client / JetBrains HTTP)
        if lowerName.hasSuffix(".http") || lowerName.hasSuffix(".rest") || looksLikeHTTPFile(trimmed) {
            let col = parseHTTPFile(trimmed, defaultName: fileName.map { ($0 as NSString).deletingPathExtension } ?? "Imported HTTP Requests")
            if col.totalRequestCount > 0 {
                return APIImportOutcome(detectedFormat: .httpFile, collections: [col])
            }
        }

        // 4. Try .env file
        if lowerName.hasSuffix(".env") || lowerName.contains(".env.") {
            let env = parseDotEnv(trimmed, name: fileName ?? "Imported .env")
            if !env.variables.isEmpty {
                return APIImportOutcome(detectedFormat: .ceptra, environments: [env])
            }
        }

        throw APIFormatCodecError.unsupportedFormat("Expected Postman JSON, Insomnia v4 JSON, OpenAPI JSON, HAR 1.2, .http/.rest, .env, or cURL.")
    }

    // MARK: - Postman Collection v2.1 / v2.0 Import

    private static func importPostmanCollection(_ dict: [String: Any], fileName: String?) -> APIImportOutcome {
        let info = dict["info"] as? [String: Any] ?? [:]
        let name = nonEmpty(info["name"] as? String)
            ?? fileName.map { ($0 as NSString).deletingPathExtension }
            ?? "Postman Collection"
        let desc = extractPostmanDescription(info["description"])
        let auth = parsePostmanAuth(dict["auth"] as? [String: Any], defaultKind: .none)
        let variables = parsePostmanVariables(dict["variable"] as? [[String: Any]] ?? [])

        var folders: [APIFolder] = []
        var requests: [APIRequestItem] = []
        let items = dict["item"] as? [[String: Any]] ?? []
        for item in items {
            if item["item"] is [Any] {
                folders.append(parsePostmanFolder(item))
            } else if item["request"] != nil {
                requests.append(parsePostmanRequestItem(item))
            }
        }

        let collection = APICollection(
            name: name,
            description: desc,
            sourceFormat: .postmanV21,
            auth: auth,
            variables: variables,
            folders: folders,
            requests: requests
        )
        return APIImportOutcome(detectedFormat: .postmanV21, collections: [collection])
    }

    private static func parsePostmanFolder(_ dict: [String: Any]) -> APIFolder {
        let name = nonEmpty(dict["name"] as? String) ?? "Folder"
        let desc = extractPostmanDescription(dict["description"])
        let auth = parsePostmanAuth(dict["auth"] as? [String: Any], defaultKind: .inherit)
        var subFolders: [APIFolder] = []
        var subRequests: [APIRequestItem] = []
        for child in (dict["item"] as? [[String: Any]] ?? []) {
            if child["item"] is [Any] {
                subFolders.append(parsePostmanFolder(child))
            } else if child["request"] != nil {
                subRequests.append(parsePostmanRequestItem(child))
            }
        }
        return APIFolder(name: name, description: desc, auth: auth, folders: subFolders, requests: subRequests)
    }

    private static func parsePostmanRequestItem(_ item: [String: Any]) -> APIRequestItem {
        let name = nonEmpty(item["name"] as? String) ?? "Request"
        let events = item["event"] as? [[String: Any]] ?? []
        var preScript = ""
        var testScript = ""
        for ev in events {
            let listen = (ev["listen"] as? String)?.lowercased() ?? ""
            if let script = ev["script"] as? [String: Any],
               let exec = script["exec"] as? [String] {
                let joined = exec.joined(separator: "\n")
                if listen == "prerequest" { preScript = joined }
                if listen == "test" { testScript = joined }
            }
        }

        // Request can be a raw string URL or a structured object
        if let rawURL = item["request"] as? String {
            let (assertions, extractors) = parsePostmanTestScriptHints(testScript)
            return APIRequestItem(
                name: name,
                method: .get,
                url: rawURL,
                assertions: assertions,
                extractors: extractors,
                preRequestScript: preScript,
                postResponseScript: testScript
            )
        }

        let req = item["request"] as? [String: Any] ?? [:]
        let method = APIHTTPMethod.from(raw: (req["method"] as? String) ?? "GET")
        let reqDesc = extractPostmanDescription(req["description"])
        let desc = reqDesc.isEmpty ? extractPostmanDescription(item["description"]) : reqDesc
        let (urlString, queryParams) = parsePostmanURL(req["url"])
        let headers: [APIKeyValueItem] = (req["header"] as? [[String: Any]] ?? []).compactMap { h in
            let k = (h["key"] as? String) ?? ""
            let v = (h["value"] as? String) ?? ""
            guard !k.isEmpty || !v.isEmpty else { return nil }
            let disabled = (h["disabled"] as? Bool) ?? false
            return APIKeyValueItem(key: k, value: v, description: extractPostmanDescription(h["description"]), isEnabled: !disabled)
        }
        let auth = parsePostmanAuth(req["auth"] as? [String: Any], defaultKind: .inherit)
        let body = parsePostmanBody(req["body"] as? [String: Any])
        let (assertions, extractors) = parsePostmanTestScriptHints(testScript)

        return APIRequestItem(
            name: name,
            description: desc,
            method: method,
            url: urlString,
            queryParams: queryParams,
            headers: headers,
            auth: auth,
            body: body,
            assertions: assertions,
            extractors: extractors,
            preRequestScript: preScript,
            postResponseScript: testScript
        )
    }

    private static func parsePostmanURL(_ rawObj: Any?) -> (String, [APIKeyValueItem]) {
        if let str = rawObj as? String {
            return splitURLAndQueryParams(str)
        }
        guard let dict = rawObj as? [String: Any] else { return ("", []) }

        var queryItems: [APIKeyValueItem] = []
        if let queries = dict["query"] as? [[String: Any]] {
            for q in queries {
                let k = (q["key"] as? String) ?? ""
                let v = (q["value"] as? String) ?? ""
                let disabled = (q["disabled"] as? Bool) ?? false
                if !k.isEmpty || !v.isEmpty {
                    queryItems.append(APIKeyValueItem(key: k, value: v, description: extractPostmanDescription(q["description"]), isEnabled: !disabled))
                }
            }
        }

        if let raw = dict["raw"] as? String, !raw.isEmpty {
            if !queryItems.isEmpty {
                // Strip query string from base URL since structured query array already preserves enabled/disabled states
                let base = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
                return (base, queryItems)
            }
            return splitURLAndQueryParams(raw)
        }

        let proto = nonEmpty(dict["protocol"] as? String)
        let host: String
        if let hostArr = dict["host"] as? [String] {
            host = hostArr.joined(separator: ".")
        } else {
            host = (dict["host"] as? String) ?? ""
        }
        let port = nonEmpty(dict["port"] as? String).map { ":\($0)" } ?? ""
        let path: String
        if let pathArr = dict["path"] as? [String] {
            path = pathArr.isEmpty ? "" : "/" + pathArr.joined(separator: "/")
        } else if let p = dict["path"] as? String {
            path = p.hasPrefix("/") || p.isEmpty ? p : "/" + p
        } else {
            path = ""
        }
        let prefix = proto.map { "\($0)://" } ?? ""
        return ("\(prefix)\(host)\(port)\(path)", queryItems)
    }

    private static func parsePostmanAuth(_ dict: [String: Any]?, defaultKind: APIAuthConfig.Kind) -> APIAuthConfig {
        guard let dict, let type = (dict["type"] as? String)?.lowercased() else {
            return APIAuthConfig(kind: defaultKind)
        }

        func extractKVMap(_ raw: Any?) -> [String: String] {
            if let arr = raw as? [[String: Any]] {
                var map: [String: String] = [:]
                for entry in arr {
                    if let k = entry["key"] as? String {
                        map[k] = (entry["value"] as? String) ?? ""
                    }
                }
                return map
            }
            if let d = raw as? [String: Any] {
                return d.compactMapValues { $0 as? String }
            }
            return [:]
        }

        switch type {
        case "noauth":
            return APIAuthConfig(kind: .none)
        case "bearer":
            let m = extractKVMap(dict["bearer"])
            return APIAuthConfig(kind: .bearer, bearerToken: m["token"] ?? "")
        case "basic":
            let m = extractKVMap(dict["basic"])
            return APIAuthConfig(kind: .basic, basicUsername: m["username"] ?? "", basicPassword: m["password"] ?? "")
        case "apikey":
            let m = extractKVMap(dict["apikey"])
            let loc: APIKeyLocation = (m["in"]?.lowercased() == "query") ? .query : .header
            return APIAuthConfig(
                kind: .apiKey,
                apiKeyName: nonEmpty(m["key"]) ?? "X-API-Key",
                apiKeyValue: m["value"] ?? "",
                apiKeyIn: loc
            )
        default:
            return APIAuthConfig(kind: defaultKind)
        }
    }

    private static func parsePostmanBody(_ dict: [String: Any]?) -> APIBodyConfig {
        guard let dict, let mode = (dict["mode"] as? String)?.lowercased() else {
            return APIBodyConfig()
        }
        switch mode {
        case "raw":
            let raw = (dict["raw"] as? String) ?? ""
            let lang = ((dict["options"] as? [String: Any])?["raw"] as? [String: Any])?["language"] as? String
            let isJSON = lang?.lowercased() == "json" || raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") || raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
            let ct: String
            switch lang?.lowercased() {
            case "xml": ct = "application/xml"
            case "html": ct = "text/html"
            case "javascript": ct = "application/javascript"
            default: ct = "text/plain"
            }
            return APIBodyConfig(mode: isJSON ? .json : .raw, rawText: raw, rawContentType: ct)

        case "urlencoded":
            let items: [APIKeyValueItem] = (dict["urlencoded"] as? [[String: Any]] ?? []).map { entry in
                APIKeyValueItem(
                    key: (entry["key"] as? String) ?? "",
                    value: (entry["value"] as? String) ?? "",
                    description: extractPostmanDescription(entry["description"]),
                    isEnabled: !((entry["disabled"] as? Bool) ?? false)
                )
            }
            return APIBodyConfig(mode: .formURLEncoded, formItems: items)

        case "formdata":
            let items: [APIKeyValueItem] = (dict["formdata"] as? [[String: Any]] ?? []).map { entry in
                let isFile = (entry["type"] as? String)?.lowercased() == "file"
                let src = entry["src"] as? String
                return APIKeyValueItem(
                    key: (entry["key"] as? String) ?? "",
                    value: (entry["value"] as? String) ?? "",
                    description: extractPostmanDescription(entry["description"]),
                    isEnabled: !((entry["disabled"] as? Bool) ?? false),
                    filePath: isFile ? src : nil
                )
            }
            return APIBodyConfig(mode: .multipartFormData, formItems: items)

        case "graphql":
            let gql = dict["graphql"] as? [String: Any] ?? [:]
            return APIBodyConfig(
                mode: .graphql,
                graphqlQuery: (gql["query"] as? String) ?? "",
                graphqlVariables: nonEmpty(gql["variables"] as? String) ?? "{}"
            )

        default:
            return APIBodyConfig()
        }
    }

    private static func parsePostmanVariables(_ arr: [[String: Any]]) -> [APIKeyValueItem] {
        arr.compactMap { v in
            let k = (v["key"] as? String) ?? ""
            guard !k.isEmpty else { return nil }
            let val = stringifyAny(v["value"])
            let disabled = (v["disabled"] as? Bool) ?? false
            let isSecret = (v["type"] as? String)?.lowercased() == "secret"
            return APIKeyValueItem(key: k, value: val, isEnabled: !disabled, isSecret: isSecret)
        }
    }

    private static func importPostmanEnvironment(_ dict: [String: Any], fileName: String?) -> APIImportOutcome {
        let name = nonEmpty(dict["name"] as? String)
            ?? fileName.map { ($0 as NSString).deletingPathExtension }
            ?? "Postman Environment"
        let rawValues = dict["values"] as? [[String: Any]] ?? []
        let vars: [APIEnvironmentVariable] = rawValues.compactMap { entry in
            let k = (entry["key"] as? String) ?? ""
            guard !k.isEmpty else { return nil }
            let val = stringifyAny(entry["value"])
            let enabled = (entry["enabled"] as? Bool) ?? true
            let isSecret = (entry["type"] as? String)?.lowercased() == "secret" || looksLikeSecretKey(k)
            return APIEnvironmentVariable(
                key: k,
                initialValue: isSecret ? "" : val,
                currentValue: val,
                isEnabled: enabled,
                isSecret: isSecret
            )
        }
        let env = APIEnvironment(name: name, sourceFormat: .postmanV21, variables: vars)
        return APIImportOutcome(detectedFormat: .postmanV21, environments: [env])
    }

    /// Extracts common declarative Postman test assertions and variable setters into editable Ceptra rules.
    public static func parsePostmanTestScriptHints(_ script: String) -> ([APIAssertionRule], [APIVariableExtractor]) {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ([], [])
        }
        var assertions: [APIAssertionRule] = []
        var extractors: [APIVariableExtractor] = []

        // 1. pm.response.to.have.status(200) / pm.expect(pm.response.code).to.eql(201)
        if let statusRegex = try? NSRegularExpression(pattern: #"(?:pm\.response\.to\.have\.status|pm\.expect\(pm\.response\.code\)\.to\.(?:equal|eql|be))\(\s*(\d{3})\s*\)"#) {
            let ns = script as NSString
            for m in statusRegex.matches(in: script, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 2 {
                let code = ns.substring(with: m.range(at: 1))
                if !assertions.contains(where: { $0.target == .statusCode && $0.expectedValue == code }) {
                    assertions.append(APIAssertionRule(name: "Status is \(code)", target: .statusCode, op: .equals, expectedValue: code))
                }
            }
        }

        // 2. pm.expect(pm.response.responseTime).to.be.below(500)
        if let timeRegex = try? NSRegularExpression(pattern: #"responseTime\)\.to\.be\.below\(\s*(\d+)\s*\)"#) {
            let ns = script as NSString
            for m in timeRegex.matches(in: script, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 2 {
                let ms = ns.substring(with: m.range(at: 1))
                assertions.append(APIAssertionRule(name: "Response time < \(ms)ms", target: .responseTimeMs, op: .lessThan, expectedValue: ms))
            }
        }

        // 3. pm.environment.set("token", jsonData.access_token) / pm.collectionVariables.set(...)
        if let setRegex = try? NSRegularExpression(pattern: #"pm\.(environment|collectionVariables)\.set\(\s*["']([^"']+)["']\s*,\s*[a-zA-Z_$][a-zA-Z0-9_$]*\.([a-zA-Z0-9_.\[\]]+)\s*\)"#) {
            let ns = script as NSString
            for m in setRegex.matches(in: script, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 4 {
                let scopeStr = ns.substring(with: m.range(at: 1))
                let varName = ns.substring(with: m.range(at: 2))
                let path = ns.substring(with: m.range(at: 3))
                let scope: APIVariableExtractor.Scope = (scopeStr == "collectionVariables") ? .collection : .environment
                extractors.append(APIVariableExtractor(source: .jsonPath, expression: "$." + path, targetVariableName: varName, scope: scope))
            }
        }

        return (assertions, extractors)
    }

    // MARK: - Insomnia v4 JSON Import

    private static func importInsomniaV4(_ dict: [String: Any], fileName: String?) throws -> APIImportOutcome {
        let resources = dict["resources"] as? [[String: Any]] ?? []
        guard !resources.isEmpty else {
            throw APIFormatCodecError.unsupportedFormat("Insomnia v4 export contains no resources.")
        }

        var workspacesByID: [String: [String: Any]] = [:]
        var groupsByID: [String: [String: Any]] = [:]
        var requestsByParent: [String: [[String: Any]]] = [:]
        var groupsByParent: [String: [[String: Any]]] = [:]
        var rawEnvs: [[String: Any]] = []

        for res in resources {
            let rtype = (res["_type"] as? String)?.lowercased() ?? ""
            let rid = (res["_id"] as? String) ?? UUID().uuidString
            let parentID = (res["parentId"] as? String) ?? ""

            switch rtype {
            case "workspace":
                workspacesByID[rid] = res
            case "request_group":
                groupsByID[rid] = res
                groupsByParent[parentID, default: []].append(res)
            case "request":
                requestsByParent[parentID, default: []].append(res)
            case "environment":
                rawEnvs.append(res)
            default:
                break
            }
        }

        func sortByMetaKey(_ list: [[String: Any]]) -> [[String: Any]] {
            list.sorted { a, b in
                let ka = (a["metaSortKey"] as? Double) ?? 0
                let kb = (b["metaSortKey"] as? Double) ?? 0
                return ka < kb
            }
        }

        func buildRequest(_ res: [String: Any]) -> APIRequestItem {
            let name = nonEmpty(res["name"] as? String) ?? "Request"
            let desc = (res["description"] as? String) ?? ""
            let method = APIHTTPMethod.from(raw: (res["method"] as? String) ?? "GET")
            let rawURL = APIVariableResolver.normalizeInsomniaTemplates((res["url"] as? String) ?? "")

            var queryParams: [APIKeyValueItem] = (res["parameters"] as? [[String: Any]] ?? []).compactMap { p in
                let k = APIVariableResolver.normalizeInsomniaTemplates((p["name"] as? String) ?? "")
                let v = APIVariableResolver.normalizeInsomniaTemplates((p["value"] as? String) ?? "")
                guard !k.isEmpty || !v.isEmpty else { return nil }
                let disabled = (p["disabled"] as? Bool) ?? false
                return APIKeyValueItem(key: k, value: v, description: (p["description"] as? String) ?? "", isEnabled: !disabled)
            }
            let finalURL: String
            if queryParams.isEmpty {
                let split = splitURLAndQueryParams(rawURL)
                finalURL = split.0
                queryParams = split.1
            } else {
                finalURL = rawURL.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawURL
            }

            let headers: [APIKeyValueItem] = (res["headers"] as? [[String: Any]] ?? []).compactMap { h in
                let k = APIVariableResolver.normalizeInsomniaTemplates((h["name"] as? String) ?? "")
                let v = APIVariableResolver.normalizeInsomniaTemplates((h["value"] as? String) ?? "")
                guard !k.isEmpty || !v.isEmpty else { return nil }
                let disabled = (h["disabled"] as? Bool) ?? false
                return APIKeyValueItem(key: k, value: v, isEnabled: !disabled)
            }

            let auth = parseInsomniaAuth(res["authentication"] as? [String: Any])
            let body = parseInsomniaBody(res["body"] as? [String: Any])

            return APIRequestItem(
                name: name,
                description: desc,
                method: method,
                url: finalURL,
                queryParams: queryParams,
                headers: headers,
                auth: auth,
                body: body
            )
        }

        func buildFolder(_ group: [String: Any]) -> APIFolder {
            let gid = (group["_id"] as? String) ?? ""
            let name = nonEmpty(group["name"] as? String) ?? "Folder"
            let desc = (group["description"] as? String) ?? ""
            let childFolders = sortByMetaKey(groupsByParent[gid] ?? []).map(buildFolder)
            let childReqs = sortByMetaKey(requestsByParent[gid] ?? []).map(buildRequest)
            return APIFolder(name: name, description: desc, auth: .inherit, folders: childFolders, requests: childReqs)
        }

        // Build Environments (merging base environment variables into sub-environments)
        var baseDataByEnvID: [String: [String: String]] = [:]
        for env in rawEnvs {
            let eid = (env["_id"] as? String) ?? ""
            let flat = flattenJSONDictionary(env["data"] as? [String: Any] ?? [:])
            baseDataByEnvID[eid] = flat
        }

        var environments: [APIEnvironment] = []
        for env in sortByMetaKey(rawEnvs) {
            let name = nonEmpty(env["name"] as? String) ?? "Insomnia Environment"
            let parentID = (env["parentId"] as? String) ?? ""
            var merged: [String: String] = baseDataByEnvID[parentID] ?? [:]
            let own = flattenJSONDictionary(env["data"] as? [String: Any] ?? [:])
            for (k, v) in own { merged[k] = v }
            // Skip completely empty Base Environment if sub-environments exist
            let isBase = workspacesByID[parentID] != nil
            if isBase && merged.isEmpty && rawEnvs.count > 1 { continue }

            let vars = merged.keys.sorted().map { k -> APIEnvironmentVariable in
                let val = APIVariableResolver.normalizeInsomniaTemplates(merged[k] ?? "")
                let secret = looksLikeSecretKey(k)
                return APIEnvironmentVariable(key: k, initialValue: secret ? "" : val, currentValue: val, isEnabled: true, isSecret: secret)
            }
            environments.append(APIEnvironment(name: name, sourceFormat: .insomniaV4, variables: vars))
        }

        // Build Collections (one per Insomnia workspace, or one default collection)
        var collections: [APICollection] = []
        if !workspacesByID.isEmpty {
            for (wid, ws) in workspacesByID.sorted(by: { $0.key < $1.key }) {
                let colName = nonEmpty(ws["name"] as? String)
                    ?? fileName.map { ($0 as NSString).deletingPathExtension }
                    ?? "Insomnia Workspace"
                let desc = (ws["description"] as? String) ?? ""
                let folders = sortByMetaKey(groupsByParent[wid] ?? []).map(buildFolder)
                let reqs = sortByMetaKey(requestsByParent[wid] ?? []).map(buildRequest)
                if !folders.isEmpty || !reqs.isEmpty {
                    collections.append(APICollection(
                        name: colName,
                        description: desc,
                        sourceFormat: .insomniaV4,
                        folders: folders,
                        requests: reqs
                    ))
                }
            }
        }

        // Catch orphaned folders/requests if export lacked a workspace resource
        if collections.isEmpty {
            let knownGroupIDs = Set(groupsByID.keys)
            let rootGroups = sortByMetaKey(groupsByID.values.filter { g in
                let p = (g["parentId"] as? String) ?? ""
                return !knownGroupIDs.contains(p)
            }).map(buildFolder)
            let rootReqs = sortByMetaKey(requestsByParent.flatMap { parent, list in
                knownGroupIDs.contains(parent) ? [] : list
            }).map(buildRequest)
            if !rootGroups.isEmpty || !rootReqs.isEmpty {
                let colName = fileName.map { ($0 as NSString).deletingPathExtension } ?? "Insomnia Collection"
                collections.append(APICollection(name: colName, sourceFormat: .insomniaV4, folders: rootGroups, requests: rootReqs))
            }
        }

        return APIImportOutcome(detectedFormat: .insomniaV4, collections: collections, environments: environments)
    }

    private static func parseInsomniaAuth(_ dict: [String: Any]?) -> APIAuthConfig {
        guard let dict, let type = (dict["type"] as? String)?.lowercased() else {
            return .inherit
        }
        if (dict["disabled"] as? Bool) == true { return .none }
        switch type {
        case "bearer":
            return APIAuthConfig(kind: .bearer, bearerToken: APIVariableResolver.normalizeInsomniaTemplates((dict["token"] as? String) ?? ""))
        case "basic":
            return APIAuthConfig(
                kind: .basic,
                basicUsername: APIVariableResolver.normalizeInsomniaTemplates((dict["username"] as? String) ?? ""),
                basicPassword: APIVariableResolver.normalizeInsomniaTemplates((dict["password"] as? String) ?? "")
            )
        case "apikey":
            let addTo = (dict["addTo"] as? String)?.lowercased() == "queryparams" ? APIKeyLocation.query : .header
            return APIAuthConfig(
                kind: .apiKey,
                apiKeyName: nonEmpty(dict["key"] as? String) ?? "X-API-Key",
                apiKeyValue: APIVariableResolver.normalizeInsomniaTemplates((dict["value"] as? String) ?? ""),
                apiKeyIn: addTo
            )
        case "none":
            return .none
        default:
            return .inherit
        }
    }

    private static func parseInsomniaBody(_ dict: [String: Any]?) -> APIBodyConfig {
        guard let dict else { return APIBodyConfig() }
        let mime = ((dict["mimeType"] as? String) ?? "").lowercased()
        let text = APIVariableResolver.normalizeInsomniaTemplates((dict["text"] as? String) ?? "")

        if mime.contains("graphql") {
            if let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let query = (parsed["query"] as? String) ?? ""
                let varsObj = parsed["variables"]
                let varsStr: String
                if let varsObj, JSONSerialization.isValidJSONObject(varsObj),
                   let vd = try? JSONSerialization.data(withJSONObject: varsObj, options: [.prettyPrinted, .sortedKeys]),
                   let vs = String(data: vd, encoding: .utf8) {
                    varsStr = vs
                } else {
                    varsStr = "{}"
                }
                return APIBodyConfig(mode: .graphql, graphqlQuery: query, graphqlVariables: varsStr)
            }
            return APIBodyConfig(mode: .graphql, graphqlQuery: text, graphqlVariables: "{}")
        }

        if mime.contains("json") {
            return APIBodyConfig(mode: .json, rawText: text)
        }
        if mime.contains("x-www-form-urlencoded") {
            let items: [APIKeyValueItem] = (dict["params"] as? [[String: Any]] ?? []).map { p in
                APIKeyValueItem(
                    key: APIVariableResolver.normalizeInsomniaTemplates((p["name"] as? String) ?? ""),
                    value: APIVariableResolver.normalizeInsomniaTemplates((p["value"] as? String) ?? ""),
                    isEnabled: !((p["disabled"] as? Bool) ?? false)
                )
            }
            return APIBodyConfig(mode: .formURLEncoded, formItems: items)
        }
        if mime.contains("multipart/form-data") {
            let items: [APIKeyValueItem] = (dict["params"] as? [[String: Any]] ?? []).map { p in
                APIKeyValueItem(
                    key: APIVariableResolver.normalizeInsomniaTemplates((p["name"] as? String) ?? ""),
                    value: APIVariableResolver.normalizeInsomniaTemplates((p["value"] as? String) ?? ""),
                    isEnabled: !((p["disabled"] as? Bool) ?? false),
                    filePath: p["fileName"] as? String
                )
            }
            return APIBodyConfig(mode: .multipartFormData, formItems: items)
        }
        if !text.isEmpty {
            return APIBodyConfig(mode: .raw, rawText: text, rawContentType: mime.isEmpty ? "text/plain" : mime)
        }
        return APIBodyConfig()
    }

    // MARK: - OpenAPI 3.x / Swagger 2.0 JSON Import

    private static func importOpenAPI(_ dict: [String: Any], fileName: String?) -> APIImportOutcome {
        let info = dict["info"] as? [String: Any] ?? [:]
        let title = nonEmpty(info["title"] as? String)
            ?? fileName.map { ($0 as NSString).deletingPathExtension }
            ?? "OpenAPI Specification"
        let desc = (info["description"] as? String) ?? ""

        // Extract base URL
        var baseURL = "https://api.example.com"
        if let servers = dict["servers"] as? [[String: Any]], let firstURL = servers.first?["url"] as? String, !firstURL.isEmpty {
            baseURL = firstURL
        } else if let host = dict["host"] as? String, !host.isEmpty {
            let scheme = (dict["schemes"] as? [String])?.first ?? "https"
            let basePath = (dict["basePath"] as? String) ?? ""
            baseURL = "\(scheme)://\(host)\(basePath)"
        }
        if baseURL.hasSuffix("/") { baseURL.removeLast() }

        let paths = dict["paths"] as? [String: Any] ?? [:]
        var requestsByTag: [String: [APIRequestItem]] = [:]
        var untagged: [APIRequestItem] = []

        let supportedMethods = ["get", "post", "put", "patch", "delete", "head", "options"]
        for pathKey in paths.keys.sorted() {
            guard let pathObj = paths[pathKey] as? [String: Any] else { continue }
            let sharedParams = pathObj["parameters"] as? [[String: Any]] ?? []
            // Convert OpenAPI `{id}` path params into `{{id}}`
            let templatedPath = pathKey.replacingOccurrences(of: #"\{([^}]+)\}"#, with: "{{$1}}", options: .regularExpression)

            for methodKey in supportedMethods {
                guard let op = pathObj[methodKey] as? [String: Any] else { continue }
                let method = APIHTTPMethod.from(raw: methodKey)
                let summary = nonEmpty(op["summary"] as? String)
                    ?? nonEmpty(op["operationId"] as? String)
                    ?? "\(method.rawValue) \(pathKey)"

                var queryParams: [APIKeyValueItem] = []
                var headers: [APIKeyValueItem] = [APIKeyValueItem(key: "Accept", value: "application/json")]
                let allParams = sharedParams + (op["parameters"] as? [[String: Any]] ?? [])
                for p in allParams {
                    let pname = (p["name"] as? String) ?? ""
                    guard !pname.isEmpty else { continue }
                    let loc = (p["in"] as? String)?.lowercased() ?? ""
                    let sampleVal = stringifyAny(p["example"] ?? (p["schema"] as? [String: Any])?["default"] ?? "")
                    let required = (p["required"] as? Bool) ?? false
                    if loc == "query" {
                        queryParams.append(APIKeyValueItem(key: pname, value: sampleVal, description: (p["description"] as? String) ?? "", isEnabled: required || !sampleVal.isEmpty))
                    } else if loc == "header" {
                        headers.append(APIKeyValueItem(key: pname, value: sampleVal, isEnabled: required || !sampleVal.isEmpty))
                    }
                }

                var body = APIBodyConfig()
                if let reqBody = op["requestBody"] as? [String: Any],
                   let content = reqBody["content"] as? [String: Any],
                   let jsonMedia = content["application/json"] as? [String: Any] {
                    headers.append(APIKeyValueItem(key: "Content-Type", value: "application/json"))
                    let sample = synthesizeOpenAPIExample(media: jsonMedia)
                    body = APIBodyConfig(mode: .json, rawText: sample)
                }

                let item = APIRequestItem(
                    name: summary,
                    description: (op["description"] as? String) ?? "",
                    method: method,
                    url: "{{baseUrl}}\(templatedPath)",
                    queryParams: queryParams,
                    headers: headers,
                    auth: .inherit,
                    body: body
                )

                if let firstTag = (op["tags"] as? [String])?.first, !firstTag.isEmpty {
                    requestsByTag[firstTag, default: []].append(item)
                } else {
                    untagged.append(item)
                }
            }
        }

        let folders = requestsByTag.keys.sorted().map { tag in
            APIFolder(name: tag, requests: requestsByTag[tag] ?? [])
        }
        let collection = APICollection(
            name: title,
            description: desc,
            sourceFormat: .openAPI3,
            variables: [APIKeyValueItem(key: "baseUrl", value: baseURL)],
            folders: folders,
            requests: untagged
        )
        return APIImportOutcome(detectedFormat: .openAPI3, collections: [collection])
    }

    private static func synthesizeOpenAPIExample(media: [String: Any]) -> String {
        if let example = media["example"] {
            return prettyJSONAny(example)
        }
        if let schema = media["schema"] as? [String: Any] {
            let built = buildSampleFromSchema(schema, depth: 0)
            return prettyJSONAny(built)
        }
        return "{\n  \n}"
    }

    private static func buildSampleFromSchema(_ schema: [String: Any], depth: Int) -> Any {
        if depth > 4 { return [:] }
        if let ex = schema["example"] { return ex }
        if let def = schema["default"] { return def }
        let type = (schema["type"] as? String)?.lowercased() ?? (schema["properties"] != nil ? "object" : "string")
        switch type {
        case "object":
            var out: [String: Any] = [:]
            if let props = schema["properties"] as? [String: Any] {
                for (k, v) in props {
                    if let sub = v as? [String: Any] {
                        out[k] = buildSampleFromSchema(sub, depth: depth + 1)
                    }
                }
            }
            return out
        case "array":
            if let items = schema["items"] as? [String: Any] {
                return [buildSampleFromSchema(items, depth: depth + 1)]
            }
            return []
        case "integer", "number":
            return 0
        case "boolean":
            return true
        default:
            if let enumVals = schema["enum"] as? [Any], let first = enumVals.first {
                return first
            }
            return ""
        }
    }

    // MARK: - HAR 1.2 Import

    private static func importHAR(_ log: [String: Any], fileName: String?) -> APIImportOutcome {
        let entries = log["entries"] as? [[String: Any]] ?? []
        let skipHeaders: Set<String> = ["host", "content-length", "connection", "accept-encoding", ":authority", ":method", ":path", ":scheme"]
        var requests: [APIRequestItem] = []

        for entry in entries {
            guard let req = entry["request"] as? [String: Any],
                  let urlStr = req["url"] as? String,
                  !urlStr.isEmpty else { continue }
            let method = APIHTTPMethod.from(raw: (req["method"] as? String) ?? "GET")
            let (baseURL, queryParams) = splitURLAndQueryParams(urlStr)

            let headers: [APIKeyValueItem] = (req["headers"] as? [[String: Any]] ?? []).compactMap { h in
                let k = (h["name"] as? String) ?? ""
                let v = (h["value"] as? String) ?? ""
                guard !k.isEmpty, !skipHeaders.contains(k.lowercased()), !k.hasPrefix(":") else { return nil }
                return APIKeyValueItem(key: k, value: v)
            }

            var body = APIBodyConfig()
            if let post = req["postData"] as? [String: Any] {
                let mime = ((post["mimeType"] as? String) ?? "").lowercased()
                let txt = (post["text"] as? String) ?? ""
                if mime.contains("json") {
                    body = APIBodyConfig(mode: .json, rawText: txt)
                } else if mime.contains("x-www-form-urlencoded"), let params = post["params"] as? [[String: Any]] {
                    let items = params.map { APIKeyValueItem(key: ($0["name"] as? String) ?? "", value: ($0["value"] as? String) ?? "") }
                    body = APIBodyConfig(mode: .formURLEncoded, formItems: items)
                } else if !txt.isEmpty {
                    body = APIBodyConfig(mode: .raw, rawText: txt, rawContentType: mime.isEmpty ? "text/plain" : mime)
                }
            }

            let pathLabel = URL(string: baseURL)?.path
            let name = "\(method.rawValue) \((pathLabel?.isEmpty == false ? pathLabel! : baseURL))"
            requests.append(APIRequestItem(name: name, method: method, url: baseURL, queryParams: queryParams, headers: headers, auth: .none, body: body))
        }

        let colName = fileName.map { ($0 as NSString).deletingPathExtension } ?? "Imported HAR"
        return APIImportOutcome(
            detectedFormat: .har,
            collections: [APICollection(name: colName, sourceFormat: .har, requests: requests)]
        )
    }

    // MARK: - cURL Parser

    public static func parseCurlCommands(_ rawInput: String) -> [APIRequestItem] {
        // Normalize line continuations (`\` + newline)
        let normalized = rawInput
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")

        var chunks: [String] = []
        var current: [String] = []
        for line in normalized.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if t.lowercased().hasPrefix("curl ") && !current.isEmpty {
                chunks.append(current.joined(separator: " "))
                current = [t]
            } else {
                current.append(t)
            }
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
        }

        return chunks.compactMap(parseSingleCurl)
    }

    private static func parseSingleCurl(_ command: String) -> APIRequestItem? {
        let tokens = shellTokenize(command)
        guard !tokens.isEmpty else { return nil }
        var idx = tokens.first?.lowercased() == "curl" ? 1 : 0

        var explicitMethod: APIHTTPMethod? = nil
        var urlString = ""
        var headers: [APIKeyValueItem] = []
        var auth = APIAuthConfig.none
        var dataParts: [String] = []
        var formItems: [APIKeyValueItem] = []
        var isMultipart = false
        var forceGet = false

        while idx < tokens.count {
            let tok = tokens[idx]
            switch tok {
            case "-X", "--request":
                if idx + 1 < tokens.count {
                    explicitMethod = APIHTTPMethod.from(raw: tokens[idx + 1])
                    idx += 2
                } else { idx += 1 }
            case "-H", "--header":
                if idx + 1 < tokens.count {
                    let h = tokens[idx + 1]
                    if let colon = h.firstIndex(of: ":") {
                        let k = String(h[..<colon]).trimmingCharacters(in: .whitespaces)
                        let v = String(h[h.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        if k.lowercased() == "authorization", v.lowercased().hasPrefix("bearer ") {
                            auth = APIAuthConfig(kind: .bearer, bearerToken: String(v.dropFirst(7)).trimmingCharacters(in: .whitespaces))
                        } else {
                            headers.append(APIKeyValueItem(key: k, value: v))
                        }
                    }
                    idx += 2
                } else { idx += 1 }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode":
                if idx + 1 < tokens.count {
                    dataParts.append(tokens[idx + 1])
                    idx += 2
                } else { idx += 1 }
            case "-F", "--form":
                isMultipart = true
                if idx + 1 < tokens.count {
                    let pair = tokens[idx + 1]
                    if let eq = pair.firstIndex(of: "=") {
                        let k = String(pair[..<eq])
                        let v = String(pair[pair.index(after: eq)...])
                        if v.hasPrefix("@") {
                            formItems.append(APIKeyValueItem(key: k, value: "", filePath: String(v.dropFirst())))
                        } else {
                            formItems.append(APIKeyValueItem(key: k, value: v))
                        }
                    }
                    idx += 2
                } else { idx += 1 }
            case "-u", "--user":
                if idx + 1 < tokens.count {
                    let creds = tokens[idx + 1]
                    let parts = creds.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    auth = APIAuthConfig(kind: .basic, basicUsername: String(parts.first ?? ""), basicPassword: parts.count > 1 ? String(parts[1]) : "")
                    idx += 2
                } else { idx += 1 }
            case "-A", "--user-agent":
                if idx + 1 < tokens.count {
                    headers.append(APIKeyValueItem(key: "User-Agent", value: tokens[idx + 1]))
                    idx += 2
                } else { idx += 1 }
            case "-b", "--cookie":
                if idx + 1 < tokens.count {
                    headers.append(APIKeyValueItem(key: "Cookie", value: tokens[idx + 1]))
                    idx += 2
                } else { idx += 1 }
            case "-G", "--get":
                forceGet = true
                idx += 1
            case "--url":
                if idx + 1 < tokens.count {
                    urlString = tokens[idx + 1]
                    idx += 2
                } else { idx += 1 }
            default:
                if !tok.hasPrefix("-"), urlString.isEmpty {
                    urlString = tok
                }
                idx += 1
            }
        }

        guard !urlString.isEmpty else { return nil }
        let (baseURL, queryParams) = splitURLAndQueryParams(urlString)

        var body = APIBodyConfig()
        var finalQuery = queryParams
        if isMultipart {
            body = APIBodyConfig(mode: .multipartFormData, formItems: formItems)
        } else if !dataParts.isEmpty {
            let joined = dataParts.joined(separator: "&")
            if forceGet {
                for pair in joined.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    finalQuery.append(APIKeyValueItem(
                        key: String(kv[0]).removingPercentEncoding ?? String(kv[0]),
                        value: kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                    ))
                }
            } else {
                let ctHeader = headers.first(where: { $0.key.lowercased() == "content-type" })?.value.lowercased() ?? ""
                let trimmedData = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                if ctHeader.contains("json") || trimmedData.hasPrefix("{") || trimmedData.hasPrefix("[") {
                    body = APIBodyConfig(mode: .json, rawText: joined)
                } else if ctHeader.contains("x-www-form-urlencoded") {
                    let items = joined.split(separator: "&").map { pair -> APIKeyValueItem in
                        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        return APIKeyValueItem(
                            key: String(kv[0]).removingPercentEncoding ?? String(kv[0]),
                            value: kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                        )
                    }
                    body = APIBodyConfig(mode: .formURLEncoded, formItems: items)
                } else {
                    body = APIBodyConfig(mode: .raw, rawText: joined, rawContentType: ctHeader.isEmpty ? "text/plain" : ctHeader)
                }
            }
        }

        let method: APIHTTPMethod = forceGet
            ? .get
            : (explicitMethod ?? ((body.mode == .none) ? .get : .post))
        let label = URL(string: baseURL)?.path
        let name = "\(method.rawValue) \((label?.isEmpty == false ? label! : baseURL))"

        return APIRequestItem(name: name, method: method, url: baseURL, queryParams: finalQuery, headers: headers, auth: auth, body: body)
    }

    // MARK: - .http / .rest File Parser

    private static func looksLikeHTTPFile(_ text: String) -> Bool {
        let pattern = #"(?m)^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(?:https?://|\{\{)"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    public static func parseHTTPFile(_ text: String, defaultName: String = "HTTP Collection") -> APICollection {
        var variables: [APIKeyValueItem] = []
        var requests: [APIRequestItem] = []

        // Parse top-level `@key = value` variables
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@"), let eq = trimmed.firstIndex(of: "=") {
                let k = String(trimmed[trimmed.index(after: trimmed.startIndex)..<eq]).trimmingCharacters(in: .whitespaces)
                let v = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if !k.isEmpty {
                    variables.append(APIKeyValueItem(key: k, value: v))
                }
            }
        }

        // Split sections by `###`
        let sections = text.components(separatedBy: "\n###")
        for (idx, rawSection) in sections.enumerated() {
            var lines = rawSection.components(separatedBy: .newlines)
            var name = ""
            if idx == 0, let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("###") {
                name = first.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                lines.removeFirst()
            } else if idx > 0, let first = lines.first {
                name = first.trimmingCharacters(in: .whitespaces)
                lines.removeFirst()
            }

            // Locate request line `METHOD URL`
            var method: APIHTTPMethod? = nil
            var urlRaw = ""
            var headers: [APIKeyValueItem] = []
            var bodyLines: [String] = []
            var inBody = false

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if method == nil {
                    if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix("@") {
                        continue
                    }
                    let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                    if parts.count >= 2, let m = APIHTTPMethod(rawValue: String(parts[0]).uppercased()) {
                        method = m
                        urlRaw = String(parts[1])
                    }
                } else if !inBody {
                    if trimmed.isEmpty {
                        inBody = true
                    } else if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                        continue
                    } else if let colon = line.firstIndex(of: ":") {
                        let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                        let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        if !k.isEmpty {
                            headers.append(APIKeyValueItem(key: k, value: v))
                        }
                    }
                } else {
                    bodyLines.append(line)
                }
            }

            guard let resolvedMethod = method, !urlRaw.isEmpty else { continue }
            let (baseURL, queryParams) = splitURLAndQueryParams(urlRaw)
            let bodyText = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            var body = APIBodyConfig()
            if !bodyText.isEmpty {
                let ct = headers.first(where: { $0.key.lowercased() == "content-type" })?.value.lowercased() ?? ""
                if ct.contains("json") || bodyText.hasPrefix("{") || bodyText.hasPrefix("[") {
                    body = APIBodyConfig(mode: .json, rawText: bodyText)
                } else {
                    body = APIBodyConfig(mode: .raw, rawText: bodyText, rawContentType: ct.isEmpty ? "text/plain" : ct)
                }
            }

            let reqName = nonEmpty(name) ?? "\(resolvedMethod.rawValue) \(baseURL)"
            requests.append(APIRequestItem(name: reqName, method: resolvedMethod, url: baseURL, queryParams: queryParams, headers: headers, auth: .inherit, body: body))
        }

        return APICollection(name: defaultName, sourceFormat: .httpFile, variables: variables, requests: requests)
    }

    private static func parseDotEnv(_ text: String, name: String) -> APIEnvironment {
        var vars: [APIEnvironmentVariable] = []
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            let cleaned = t.hasPrefix("export ") ? String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) : t
            guard let eq = cleaned.firstIndex(of: "=") else { continue }
            let k = String(cleaned[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(cleaned[cleaned.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            guard !k.isEmpty else { continue }
            let secret = looksLikeSecretKey(k)
            vars.append(APIEnvironmentVariable(key: k, initialValue: secret ? "" : v, currentValue: v, isEnabled: true, isSecret: secret))
        }
        return APIEnvironment(name: name, sourceFormat: .ceptra, variables: vars)
    }

    // MARK: - Exporters (Postman v2.1, Insomnia v4, .http, .env, Ceptra Native)

    public static func exportPostmanCollectionV21(_ collection: APICollection) throws -> Data {
        func serializeAuth(_ auth: APIAuthConfig) -> [String: Any]? {
            switch auth.kind {
            case .inherit:
                return nil
            case .none:
                return ["type": "noauth"]
            case .bearer:
                return ["type": "bearer", "bearer": [["key": "token", "value": auth.bearerToken, "type": "string"]]]
            case .basic:
                return ["type": "basic", "basic": [
                    ["key": "username", "value": auth.basicUsername, "type": "string"],
                    ["key": "password", "value": auth.basicPassword, "type": "string"]
                ]]
            case .apiKey:
                return ["type": "apikey", "apikey": [
                    ["key": "key", "value": auth.apiKeyName, "type": "string"],
                    ["key": "value", "value": auth.apiKeyValue, "type": "string"],
                    ["key": "in", "value": auth.apiKeyIn.rawValue, "type": "string"]
                ]]
            }
        }

        func serializeRequestItem(_ req: APIRequestItem) -> [String: Any] {
            var urlObj: [String: Any] = ["raw": composeRawURL(baseURL: req.url, queryParams: req.queryParams)]
            if !req.queryParams.isEmpty {
                urlObj["query"] = req.queryParams.map { q -> [String: Any] in
                    var d: [String: Any] = ["key": q.key, "value": q.value]
                    if !q.isEnabled { d["disabled"] = true }
                    if !q.description.isEmpty { d["description"] = q.description }
                    return d
                }
            }

            let headersArr: [[String: Any]] = req.headers.map { h in
                var d: [String: Any] = ["key": h.key, "value": h.value, "type": "text"]
                if !h.isEnabled { d["disabled"] = true }
                if !h.description.isEmpty { d["description"] = h.description }
                return d
            }

            var reqObj: [String: Any] = [
                "method": req.method.rawValue,
                "header": headersArr,
                "url": urlObj
            ]
            if !req.description.isEmpty { reqObj["description"] = req.description }
            if let authObj = serializeAuth(req.auth) { reqObj["auth"] = authObj }

            switch req.body.mode {
            case .none:
                break
            case .json:
                reqObj["body"] = [
                    "mode": "raw",
                    "raw": req.body.rawText,
                    "options": ["raw": ["language": "json"]]
                ]
            case .raw:
                let lang = req.body.rawContentType.contains("xml") ? "xml" : (req.body.rawContentType.contains("html") ? "html" : "text")
                reqObj["body"] = [
                    "mode": "raw",
                    "raw": req.body.rawText,
                    "options": ["raw": ["language": lang]]
                ]
            case .formURLEncoded:
                reqObj["body"] = [
                    "mode": "urlencoded",
                    "urlencoded": req.body.formItems.map { item -> [String: Any] in
                        var d: [String: Any] = ["key": item.key, "value": item.value, "type": "text"]
                        if !item.isEnabled { d["disabled"] = true }
                        return d
                    }
                ]
            case .multipartFormData:
                reqObj["body"] = [
                    "mode": "formdata",
                    "formdata": req.body.formItems.map { item -> [String: Any] in
                        var d: [String: Any] = ["key": item.key]
                        if let fp = item.filePath, !fp.isEmpty {
                            d["type"] = "file"
                            d["src"] = fp
                        } else {
                            d["type"] = "text"
                            d["value"] = item.value
                        }
                        if !item.isEnabled { d["disabled"] = true }
                        return d
                    }
                ]
            case .graphql:
                reqObj["body"] = [
                    "mode": "graphql",
                    "graphql": ["query": req.body.graphqlQuery, "variables": req.body.graphqlVariables]
                ]
            }

            var events: [[String: Any]] = []
            if !req.preRequestScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append([
                    "listen": "prerequest",
                    "script": ["type": "text/javascript", "exec": req.preRequestScript.components(separatedBy: .newlines)]
                ])
            }
            let synthesizedTestScript = synthesizePostmanTestScript(for: req)
            if !synthesizedTestScript.isEmpty {
                events.append([
                    "listen": "test",
                    "script": ["type": "text/javascript", "exec": synthesizedTestScript.components(separatedBy: .newlines)]
                ])
            }

            var out: [String: Any] = ["name": req.name, "request": reqObj]
            if !events.isEmpty { out["event"] = events }
            return out
        }

        func serializeFolder(_ folder: APIFolder) -> [String: Any] {
            var children: [[String: Any]] = folder.folders.map(serializeFolder)
            children.append(contentsOf: folder.requests.map(serializeRequestItem))
            var out: [String: Any] = ["name": folder.name, "item": children]
            if !folder.description.isEmpty { out["description"] = folder.description }
            if let authObj = serializeAuth(folder.auth) { out["auth"] = authObj }
            return out
        }

        var rootItems: [[String: Any]] = collection.folders.map(serializeFolder)
        rootItems.append(contentsOf: collection.requests.map(serializeRequestItem))

        var root: [String: Any] = [
            "info": [
                "_postman_id": collection.id.uuidString.lowercased(),
                "name": collection.name,
                "description": collection.description,
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
            ],
            "item": rootItems
        ]
        if let authObj = serializeAuth(collection.auth) {
            root["auth"] = authObj
        }
        if !collection.variables.isEmpty {
            root["variable"] = collection.variables.map { v -> [String: Any] in
                var d: [String: Any] = ["key": v.key, "value": v.isSecret ? "" : v.value]
                if !v.isEnabled { d["disabled"] = true }
                if v.isSecret { d["type"] = "secret" }
                return d
            }
        }

        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func exportPostmanEnvironment(_ environment: APIEnvironment, redactSecrets: Bool = true) throws -> Data {
        let iso = ISO8601DateFormatter()
        let values: [[String: Any]] = environment.variables.map { v in
            let exportedValue: String
            if v.isSecret && redactSecrets {
                exportedValue = ""
            } else {
                exportedValue = v.initialValue.isEmpty ? v.currentValue : v.initialValue
            }
            return [
                "key": v.key,
                "value": exportedValue,
                "type": v.isSecret ? "secret" : "default",
                "enabled": v.isEnabled
            ]
        }
        let payload: [String: Any] = [
            "id": environment.id.uuidString.lowercased(),
            "name": environment.name,
            "values": values,
            "_postman_variable_scope": "environment",
            "_postman_exported_at": iso.string(from: Date()),
            "_postman_exported_using": "Ceptra API Studio"
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func exportInsomniaV4(
        collection: APICollection?,
        environment: APIEnvironment? = nil,
        redactSecrets: Bool = true
    ) throws -> Data {
        let iso = ISO8601DateFormatter()
        var resources: [[String: Any]] = []
        let wsID = "wrk_\((collection?.id ?? environment?.id ?? UUID()).uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased())"
        let baseEnvID = "env_base_\(wsID)"

        resources.append([
            "_id": wsID,
            "_type": "workspace",
            "parentId": NSNull(),
            "name": collection?.name ?? environment?.name ?? "Ceptra Workspace",
            "description": collection?.description ?? "",
            "scope": "collection"
        ])

        // Base environment holds collection variables
        var baseData: [String: Any] = [:]
        if let collection {
            for v in collection.variables where v.isEnabled && !v.key.isEmpty {
                baseData[v.key] = (v.isSecret && redactSecrets) ? "" : v.value
            }
        }
        resources.append([
            "_id": baseEnvID,
            "_type": "environment",
            "parentId": wsID,
            "name": "Base Environment",
            "data": baseData
        ])

        if let environment {
            var envData: [String: Any] = [:]
            for v in environment.variables where v.isEnabled && !v.key.isEmpty {
                envData[v.key] = (v.isSecret && redactSecrets) ? "" : (v.initialValue.isEmpty ? v.currentValue : v.initialValue)
            }
            let subEnvID = "env_\(environment.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased())"
            resources.append([
                "_id": subEnvID,
                "_type": "environment",
                "parentId": baseEnvID,
                "name": environment.name,
                "data": envData
            ])
        }

        func insomniaAuth(_ auth: APIAuthConfig) -> [String: Any] {
            switch auth.kind {
            case .bearer:
                return ["type": "bearer", "token": auth.bearerToken]
            case .basic:
                return ["type": "basic", "username": auth.basicUsername, "password": auth.basicPassword]
            case .apiKey:
                return ["type": "apikey", "key": auth.apiKeyName, "value": auth.apiKeyValue, "addTo": auth.apiKeyIn == .query ? "queryParams" : "header"]
            default:
                return [:]
            }
        }

        func insomniaBody(_ body: APIBodyConfig) -> [String: Any] {
            switch body.mode {
            case .none:
                return [:]
            case .json:
                return ["mimeType": "application/json", "text": body.rawText]
            case .raw:
                return ["mimeType": body.rawContentType, "text": body.rawText]
            case .formURLEncoded:
                return [
                    "mimeType": "application/x-www-form-urlencoded",
                    "params": body.formItems.map { ["name": $0.key, "value": $0.value, "disabled": !$0.isEnabled] }
                ]
            case .multipartFormData:
                return [
                    "mimeType": "multipart/form-data",
                    "params": body.formItems.map { item -> [String: Any] in
                        var d: [String: Any] = ["name": item.key, "value": item.value, "disabled": !item.isEnabled]
                        if let fp = item.filePath, !fp.isEmpty { d["type"] = "file"; d["fileName"] = fp }
                        return d
                    }
                ]
            case .graphql:
                var gqlPayload: [String: Any] = ["query": body.graphqlQuery]
                if let vd = body.graphqlVariables.data(using: .utf8),
                   let vo = try? JSONSerialization.jsonObject(with: vd) {
                    gqlPayload["variables"] = vo
                }
                let txt = prettyJSONAny(gqlPayload)
                return ["mimeType": "application/graphql", "text": txt]
            }
        }

        var sortCounter: Double = 0
        func appendRequest(_ req: APIRequestItem, parentID: String, effectiveAuth: APIAuthConfig) {
            sortCounter += 100
            let rid = "req_\(req.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased())"
            resources.append([
                "_id": rid,
                "_type": "request",
                "parentId": parentID,
                "name": req.name,
                "description": req.description,
                "method": req.method.rawValue,
                "url": req.url,
                "parameters": req.queryParams.map { ["name": $0.key, "value": $0.value, "disabled": !$0.isEnabled] },
                "headers": req.headers.map { ["name": $0.key, "value": $0.value, "disabled": !$0.isEnabled] },
                "authentication": insomniaAuth(effectiveAuth),
                "body": insomniaBody(req.body),
                "metaSortKey": sortCounter
            ])
        }

        func appendFolder(_ folder: APIFolder, parentID: String, inheritedAuth: APIAuthConfig) {
            sortCounter += 100
            let fid = "fld_\(folder.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased())"
            let resolvedAuth = folder.auth.kind == .inherit ? inheritedAuth : folder.auth
            resources.append([
                "_id": fid,
                "_type": "request_group",
                "parentId": parentID,
                "name": folder.name,
                "description": folder.description,
                "metaSortKey": sortCounter
            ])
            for sub in folder.folders { appendFolder(sub, parentID: fid, inheritedAuth: resolvedAuth) }
            for req in folder.requests {
                let reqAuth = req.auth.kind == .inherit ? resolvedAuth : req.auth
                appendRequest(req, parentID: fid, effectiveAuth: reqAuth)
            }
        }

        if let collection {
            let baseAuth = collection.auth.kind == .inherit ? APIAuthConfig.none : collection.auth
            for folder in collection.folders { appendFolder(folder, parentID: wsID, inheritedAuth: baseAuth) }
            for req in collection.requests {
                let reqAuth = req.auth.kind == .inherit ? baseAuth : req.auth
                appendRequest(req, parentID: wsID, effectiveAuth: reqAuth)
            }
        }

        let payload: [String: Any] = [
            "_type": "export",
            "__export_format": 4,
            "__export_date": iso.string(from: Date()),
            "__export_source": "ceptra.api.studio",
            "resources": resources
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func exportHTTPFile(_ collection: APICollection) -> String {
        var lines: [String] = ["# Exported from Ceptra API Studio — \(collection.name)", ""]
        for v in collection.variables where v.isEnabled && !v.key.isEmpty {
            lines.append("@\(v.key) = \(v.isSecret ? "" : v.value)")
        }
        if !collection.variables.isEmpty { lines.append("") }

        for entry in collection.flattenedRequests() {
            let req = entry.request
            let title = entry.folderPath.isEmpty ? req.name : "\(entry.folderPath) / \(req.name)"
            lines.append("### \(title)")
            lines.append("\(req.method.rawValue) \(composeRawURL(baseURL: req.url, queryParams: req.queryParams))")
            for h in req.headers where h.isEnabled && !h.key.isEmpty {
                lines.append("\(h.key): \(h.value)")
            }
            switch entry.effectiveAuth.kind {
            case .bearer where !entry.effectiveAuth.bearerToken.isEmpty:
                lines.append("Authorization: Bearer \(entry.effectiveAuth.bearerToken)")
            case .apiKey where entry.effectiveAuth.apiKeyIn == .header && !entry.effectiveAuth.apiKeyName.isEmpty:
                lines.append("\(entry.effectiveAuth.apiKeyName): \(entry.effectiveAuth.apiKeyValue)")
            default:
                break
            }
            switch req.body.mode {
            case .json:
                if !req.headers.contains(where: { $0.key.lowercased() == "content-type" }) {
                    lines.append("Content-Type: application/json")
                }
                lines.append("")
                lines.append(req.body.rawText)
            case .raw:
                lines.append("")
                lines.append(req.body.rawText)
            case .formURLEncoded:
                if !req.headers.contains(where: { $0.key.lowercased() == "content-type" }) {
                    lines.append("Content-Type: application/x-www-form-urlencoded")
                }
                lines.append("")
                let encoded = req.body.formItems.filter { $0.isEnabled && !$0.key.isEmpty }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
                lines.append(encoded)
            case .graphql:
                lines.append("Content-Type: application/json")
                lines.append("")
                lines.append(prettyJSONAny(["query": req.body.graphqlQuery]))
            default:
                break
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func exportDotEnv(_ environment: APIEnvironment, redactSecrets: Bool = true) -> String {
        var lines: [String] = ["# Environment: \(environment.name) (exported from Ceptra API Studio)"]
        for v in environment.variables where v.isEnabled && !v.key.isEmpty {
            let val = (v.isSecret && redactSecrets) ? "" : (v.initialValue.isEmpty ? v.currentValue : v.initialValue)
            let needsQuotes = val.contains(" ") || val.contains("#") || val.contains("=")
            let formatted = needsQuotes ? "\"\(val.replacingOccurrences(of: "\"", with: "\\\""))\"" : val
            lines.append("\(v.key)=\(formatted)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func exportCeptraBundle(collections: [APICollection], environments: [APIEnvironment], redactSecrets: Bool = true) throws -> Data {
        let sanitizedEnvs = environments.map { env -> APIEnvironment in
            var copy = env
            if redactSecrets {
                copy.variables = copy.variables.map { v in
                    var vc = v
                    if vc.isSecret { vc.initialValue = ""; vc.currentValue = "" }
                    else { vc.currentValue = vc.initialValue }
                    return vc
                }
            }
            return copy
        }
        let bundle = APIStudioWorkspaceData(version: 1, collections: collections, environments: sanitizedEnvs)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(bundle)
    }

    // MARK: - Helpers

    private static func synthesizePostmanTestScript(for req: APIRequestItem) -> String {
        if !req.postResponseScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return req.postResponseScript
        }
        var lines: [String] = []
        for rule in req.assertions where rule.isEnabled {
            switch rule.target {
            case .statusCode where rule.op == .equals:
                lines.append("pm.test(\"\(escapeJS(rule.displayTitle))\", function () { pm.response.to.have.status(\(rule.expectedValue)); });")
            case .responseTimeMs where rule.op == .lessThan:
                lines.append("pm.test(\"\(escapeJS(rule.displayTitle))\", function () { pm.expect(pm.response.responseTime).to.be.below(\(rule.expectedValue)); });")
            case .bodyContains:
                lines.append("pm.test(\"\(escapeJS(rule.displayTitle))\", function () { pm.expect(pm.response.text()).to.include(\"\(escapeJS(rule.expectedValue))\"); });")
            case .jsonPath:
                let cleanProp = rule.property.hasPrefix("$.") ? String(rule.property.dropFirst(2)) : rule.property
                if rule.op == .exists {
                    lines.append("pm.test(\"\(escapeJS(rule.displayTitle))\", function () { pm.expect(pm.response.json().\(cleanProp)).to.not.be.undefined; });")
                } else if rule.op == .equals {
                    lines.append("pm.test(\"\(escapeJS(rule.displayTitle))\", function () { pm.expect(String(pm.response.json().\(cleanProp))).to.eql(\"\(escapeJS(rule.expectedValue))\"); });")
                }
            case .header:
                lines.append("pm.test(\"\(escapeJS(rule.displayTitle))\", function () { pm.response.to.have.header(\"\(escapeJS(rule.property))\"); });")
            default:
                break
            }
        }
        for ext in req.extractors where ext.isEnabled && !ext.targetVariableName.isEmpty {
            if ext.source == .jsonPath {
                let cleanProp = ext.expression.hasPrefix("$.") ? String(ext.expression.dropFirst(2)) : ext.expression
                let setter = ext.scope == .collection ? "pm.collectionVariables.set" : "pm.environment.set"
                lines.append("\(setter)(\"\(escapeJS(ext.targetVariableName))\", pm.response.json().\(cleanProp));")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func splitURLAndQueryParams(_ rawURL: String) -> (String, [APIKeyValueItem]) {
        guard let qIndex = rawURL.firstIndex(of: "?") else {
            return (rawURL, [])
        }
        let base = String(rawURL[..<qIndex])
        let queryPart = String(rawURL[rawURL.index(after: qIndex)...])
        let hashSplit = queryPart.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let pureQuery = String(hashSplit.first ?? "")
        guard !pureQuery.isEmpty else { return (base, []) }

        let items = pureQuery.split(separator: "&", omittingEmptySubsequences: true).map { pair -> APIKeyValueItem in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            return APIKeyValueItem(key: k, value: v)
        }
        return (base, items)
    }

    public static func composeRawURL(baseURL: String, queryParams: [APIKeyValueItem]) -> String {
        let enabled = queryParams.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !enabled.isEmpty else { return baseURL }
        let sep = baseURL.contains("?") ? "&" : "?"
        let qs = enabled.map { item -> String in
            let k = item.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.key
            let v = item.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return baseURL + sep + qs
    }

    private static func extractPostmanDescription(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let d = raw as? [String: Any], let c = d["content"] as? String { return c }
        return ""
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func stringifyAny(_ value: Any?) -> String {
        guard let value else { return "" }
        return APIVariableResolver.stringifyJSONValue(value)
    }

    private static func flattenJSONDictionary(_ dict: [String: Any], prefix: String = "") -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in dict {
            let fullKey = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let nested = v as? [String: Any] {
                for (nk, nv) in flattenJSONDictionary(nested, prefix: fullKey) {
                    out[nk] = nv
                }
            } else {
                out[fullKey] = APIVariableResolver.stringifyJSONValue(v)
            }
        }
        return out
    }

    private static func looksLikeSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return ["token", "secret", "password", "passwd", "apikey", "api_key", "auth", "bearer", "private_key", "client_secret"].contains(where: { lower.contains($0) })
    }

    private static func prettyJSONAny(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return str
    }

    private static func escapeJS(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func shellTokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var buf = ""
        var quote: Character? = nil
        var escaped = false

        for ch in input {
            if escaped {
                buf.append(ch)
                escaped = false
                continue
            }
            if let q = quote {
                if ch == "\\" && q == "\"" {
                    escaped = true
                } else if ch == q {
                    quote = nil
                } else {
                    buf.append(ch)
                }
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch.isWhitespace {
                if !buf.isEmpty {
                    tokens.append(buf)
                    buf = ""
                }
            } else {
                buf.append(ch)
            }
        }
        if !buf.isEmpty { tokens.append(buf) }
        return tokens
    }
}
