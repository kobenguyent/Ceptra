import Foundation

public enum APISourceFormat: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case ceptra = "ceptra"
    case postmanV21 = "postman_v21"
    case insomniaV4 = "insomnia_v4"
    case openAPI3 = "openapi_3"
    case har = "har_12"
    case httpFile = "http_file"
    case curl = "curl"

    public var displayName: String {
        switch self {
        case .ceptra: return "Ceptra API Studio"
        case .postmanV21: return "Postman v2.1"
        case .insomniaV4: return "Insomnia v4"
        case .openAPI3: return "OpenAPI"
        case .har: return "HAR 1.2"
        case .httpFile: return ".http File"
        case .curl: return "cURL"
        }
    }
}

public enum APIHTTPMethod: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    public var id: String { rawValue }

    public static func from(raw: String) -> APIHTTPMethod {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return APIHTTPMethod(rawValue: upper) ?? .get
    }
}

public struct APIKeyValueItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String
    public var description: String
    public var isEnabled: Bool
    public var isSecret: Bool
    /// Optional local file path for multipart/form-data file uploads.
    public var filePath: String?

    public init(
        id: UUID = UUID(),
        key: String = "",
        value: String = "",
        description: String = "",
        isEnabled: Bool = true,
        isSecret: Bool = false,
        filePath: String? = nil
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.description = description
        self.isEnabled = isEnabled
        self.isSecret = isSecret
        self.filePath = filePath
    }
}

public enum APIKeyLocation: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case header
    case query

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .header: return "Header"
        case .query: return "Query Param"
        }
    }
}

public struct APIAuthConfig: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
        case inherit
        case none
        case bearer
        case basic
        case apiKey

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .inherit: return "Inherit"
            case .none: return "No Auth"
            case .bearer: return "Bearer Token"
            case .basic: return "Basic Auth"
            case .apiKey: return "API Key"
            }
        }
    }

    public var kind: Kind
    public var bearerToken: String
    public var basicUsername: String
    public var basicPassword: String
    public var apiKeyName: String
    public var apiKeyValue: String
    public var apiKeyIn: APIKeyLocation

    public init(
        kind: Kind = .inherit,
        bearerToken: String = "",
        basicUsername: String = "",
        basicPassword: String = "",
        apiKeyName: String = "X-API-Key",
        apiKeyValue: String = "",
        apiKeyIn: APIKeyLocation = .header
    ) {
        self.kind = kind
        self.bearerToken = bearerToken
        self.basicUsername = basicUsername
        self.basicPassword = basicPassword
        self.apiKeyName = apiKeyName
        self.apiKeyValue = apiKeyValue
        self.apiKeyIn = apiKeyIn
    }

    public static let none = APIAuthConfig(kind: .none)
    public static let inherit = APIAuthConfig(kind: .inherit)
}

public struct APIBodyConfig: Codable, Equatable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
        case none
        case json
        case raw
        case formURLEncoded
        case multipartFormData
        case graphql

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .none: return "None"
            case .json: return "JSON"
            case .raw: return "Raw"
            case .formURLEncoded: return "Form URL-Encoded"
            case .multipartFormData: return "Multipart Form"
            case .graphql: return "GraphQL"
            }
        }
    }

    public var mode: Mode
    public var rawText: String
    public var rawContentType: String
    public var formItems: [APIKeyValueItem]
    public var graphqlQuery: String
    public var graphqlVariables: String

    public init(
        mode: Mode = .none,
        rawText: String = "",
        rawContentType: String = "text/plain",
        formItems: [APIKeyValueItem] = [],
        graphqlQuery: String = "",
        graphqlVariables: String = "{}"
    ) {
        self.mode = mode
        self.rawText = rawText
        self.rawContentType = rawContentType
        self.formItems = formItems
        self.graphqlQuery = graphqlQuery
        self.graphqlVariables = graphqlVariables
    }
}

public struct APIAssertionRule: Identifiable, Codable, Equatable, Hashable, Sendable {
    public enum Target: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
        case statusCode
        case responseTimeMs
        case bodyContains
        case jsonPath
        case header

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .statusCode: return "Status Code"
            case .responseTimeMs: return "Response Time (ms)"
            case .bodyContains: return "Body Text"
            case .jsonPath: return "JSONPath"
            case .header: return "Header"
            }
        }
    }

    public enum OperatorKind: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
        case equals
        case notEquals
        case contains
        case lessThan
        case greaterThan
        case exists
        case matchesRegex

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .equals: return "equals"
            case .notEquals: return "not equals"
            case .contains: return "contains"
            case .lessThan: return "<"
            case .greaterThan: return ">"
            case .exists: return "exists"
            case .matchesRegex: return "matches regex"
            }
        }
    }

    public var id: UUID
    public var isEnabled: Bool
    public var name: String
    public var target: Target
    public var property: String
    public var op: OperatorKind
    public var expectedValue: String

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        name: String = "",
        target: Target = .statusCode,
        property: String = "",
        op: OperatorKind = .equals,
        expectedValue: String = "200"
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.name = name
        self.target = target
        self.property = property
        self.op = op
        self.expectedValue = expectedValue
    }

    public var displayTitle: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        switch target {
        case .statusCode:
            return "Status \(op.displayName) \(expectedValue)"
        case .responseTimeMs:
            return "Latency \(op.displayName) \(expectedValue)ms"
        case .bodyContains:
            return "Body \(op.displayName) \"\(expectedValue)\""
        case .jsonPath:
            return op == .exists ? "\(property) exists" : "\(property) \(op.displayName) \(expectedValue)"
        case .header:
            return op == .exists ? "Header \(property) exists" : "Header \(property) \(op.displayName) \(expectedValue)"
        }
    }
}

public struct APIVariableExtractor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public enum Source: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
        case jsonPath
        case header
        case regex

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .jsonPath: return "JSONPath"
            case .header: return "Header"
            case .regex: return "Regex (Group 1)"
            }
        }
    }

    public enum Scope: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
        case environment
        case collection

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .environment: return "Active Environment"
            case .collection: return "Collection"
            }
        }
    }

    public var id: UUID
    public var isEnabled: Bool
    public var source: Source
    public var expression: String
    public var targetVariableName: String
    public var scope: Scope

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        source: Source = .jsonPath,
        expression: String = "$.id",
        targetVariableName: String = "",
        scope: Scope = .environment
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.source = source
        self.expression = expression
        self.targetVariableName = targetVariableName
        self.scope = scope
    }
}

public struct APIRequestItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String
    public var method: APIHTTPMethod
    public var url: String
    public var queryParams: [APIKeyValueItem]
    public var headers: [APIKeyValueItem]
    public var auth: APIAuthConfig
    public var body: APIBodyConfig
    public var assertions: [APIAssertionRule]
    public var extractors: [APIVariableExtractor]
    /// Preserves imported Postman/Insomnia pre-request scripts for lossless round-trip export.
    public var preRequestScript: String
    /// Preserves imported Postman/Insomnia post-response test scripts for lossless round-trip export.
    public var postResponseScript: String

    public init(
        id: UUID = UUID(),
        name: String = "New Request",
        description: String = "",
        method: APIHTTPMethod = .get,
        url: String = "",
        queryParams: [APIKeyValueItem] = [],
        headers: [APIKeyValueItem] = [],
        auth: APIAuthConfig = .inherit,
        body: APIBodyConfig = APIBodyConfig(),
        assertions: [APIAssertionRule] = [],
        extractors: [APIVariableExtractor] = [],
        preRequestScript: String = "",
        postResponseScript: String = ""
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.method = method
        self.url = url
        self.queryParams = queryParams
        self.headers = headers
        self.auth = auth
        self.body = body
        self.assertions = assertions
        self.extractors = extractors
        self.preRequestScript = preRequestScript
        self.postResponseScript = postResponseScript
    }
}

public struct APIFolder: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String
    public var auth: APIAuthConfig
    public var folders: [APIFolder]
    public var requests: [APIRequestItem]

    public init(
        id: UUID = UUID(),
        name: String = "New Folder",
        description: String = "",
        auth: APIAuthConfig = .inherit,
        folders: [APIFolder] = [],
        requests: [APIRequestItem] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.auth = auth
        self.folders = folders
        self.requests = requests
    }

    public var totalRequestCount: Int {
        requests.count + folders.reduce(0) { $0 + $1.totalRequestCount }
    }

    public func flattenedRequests(inheritedAuth: APIAuthConfig) -> [(request: APIRequestItem, effectiveAuth: APIAuthConfig, folderPath: String)] {
        let resolvedAuth = auth.kind == .inherit ? inheritedAuth : auth
        var list: [(APIRequestItem, APIAuthConfig, String)] = requests.map { req in
            let reqAuth = req.auth.kind == .inherit ? resolvedAuth : req.auth
            return (req, reqAuth, name)
        }
        for sub in folders {
            for entry in sub.flattenedRequests(inheritedAuth: resolvedAuth) {
                list.append((entry.request, entry.effectiveAuth, "\(name) / \(entry.folderPath)"))
            }
        }
        return list
    }

    public func request(withID targetID: UUID, inheritedAuth: APIAuthConfig) -> (request: APIRequestItem, effectiveAuth: APIAuthConfig)? {
        let resolvedAuth = auth.kind == .inherit ? inheritedAuth : auth
        if let req = requests.first(where: { $0.id == targetID }) {
            let reqAuth = req.auth.kind == .inherit ? resolvedAuth : req.auth
            return (req, reqAuth)
        }
        for sub in folders {
            if let found = sub.request(withID: targetID, inheritedAuth: resolvedAuth) {
                return found
            }
        }
        return nil
    }

    @discardableResult
    public mutating func updateRequest(_ updated: APIRequestItem) -> Bool {
        if let idx = requests.firstIndex(where: { $0.id == updated.id }) {
            requests[idx] = updated
            return true
        }
        for idx in folders.indices {
            if folders[idx].updateRequest(updated) {
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func removeRequest(id targetID: UUID) -> Bool {
        if let idx = requests.firstIndex(where: { $0.id == targetID }) {
            requests.remove(at: idx)
            return true
        }
        for idx in folders.indices {
            if folders[idx].removeRequest(id: targetID) {
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func appendRequest(_ request: APIRequestItem, toFolderID targetFolderID: UUID) -> Bool {
        if id == targetFolderID {
            requests.append(request)
            return true
        }
        for idx in folders.indices {
            if folders[idx].appendRequest(request, toFolderID: targetFolderID) {
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func appendFolder(_ folder: APIFolder, toFolderID targetFolderID: UUID) -> Bool {
        if id == targetFolderID {
            folders.append(folder)
            return true
        }
        for idx in folders.indices {
            if folders[idx].appendFolder(folder, toFolderID: targetFolderID) {
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func removeFolder(id targetID: UUID) -> Bool {
        if let idx = folders.firstIndex(where: { $0.id == targetID }) {
            folders.remove(at: idx)
            return true
        }
        for idx in folders.indices {
            if folders[idx].removeFolder(id: targetID) {
                return true
            }
        }
        return false
    }

    public func folder(withID targetID: UUID) -> APIFolder? {
        if id == targetID { return self }
        for sub in folders {
            if let found = sub.folder(withID: targetID) {
                return found
            }
        }
        return nil
    }

    @discardableResult
    public mutating func renameFolder(id targetID: UUID, newName: String) -> Bool {
        if id == targetID {
            name = newName
            return true
        }
        for idx in folders.indices {
            if folders[idx].renameFolder(id: targetID, newName: newName) {
                return true
            }
        }
        return false
    }
}

public struct APICollection: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String
    public var sourceFormat: APISourceFormat
    public var auth: APIAuthConfig
    public var variables: [APIKeyValueItem]
    public var folders: [APIFolder]
    public var requests: [APIRequestItem]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "New Collection",
        description: String = "",
        sourceFormat: APISourceFormat = .ceptra,
        auth: APIAuthConfig = .none,
        variables: [APIKeyValueItem] = [],
        folders: [APIFolder] = [],
        requests: [APIRequestItem] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.sourceFormat = sourceFormat
        self.auth = auth
        self.variables = variables
        self.folders = folders
        self.requests = requests
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var totalRequestCount: Int {
        requests.count + folders.reduce(0) { $0 + $1.totalRequestCount }
    }

    public func flattenedRequests() -> [(request: APIRequestItem, effectiveAuth: APIAuthConfig, folderPath: String)] {
        let baseAuth = auth.kind == .inherit ? APIAuthConfig.none : auth
        var list: [(APIRequestItem, APIAuthConfig, String)] = requests.map { req in
            let reqAuth = req.auth.kind == .inherit ? baseAuth : req.auth
            return (req, reqAuth, "")
        }
        for folder in folders {
            list.append(contentsOf: folder.flattenedRequests(inheritedAuth: baseAuth))
        }
        return list
    }

    public func request(withID targetID: UUID) -> (request: APIRequestItem, effectiveAuth: APIAuthConfig)? {
        let baseAuth = auth.kind == .inherit ? APIAuthConfig.none : auth
        if let req = requests.first(where: { $0.id == targetID }) {
            let reqAuth = req.auth.kind == .inherit ? baseAuth : req.auth
            return (req, reqAuth)
        }
        for folder in folders {
            if let found = folder.request(withID: targetID, inheritedAuth: baseAuth) {
                return found
            }
        }
        return nil
    }

    public func folder(withID targetID: UUID) -> APIFolder? {
        for folder in folders {
            if let found = folder.folder(withID: targetID) {
                return found
            }
        }
        return nil
    }

    @discardableResult
    public mutating func updateRequest(_ updated: APIRequestItem) -> Bool {
        if let idx = requests.firstIndex(where: { $0.id == updated.id }) {
            requests[idx] = updated
            updatedAt = Date()
            return true
        }
        for idx in folders.indices {
            if folders[idx].updateRequest(updated) {
                updatedAt = Date()
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func removeRequest(id targetID: UUID) -> Bool {
        if let idx = requests.firstIndex(where: { $0.id == targetID }) {
            requests.remove(at: idx)
            updatedAt = Date()
            return true
        }
        for idx in folders.indices {
            if folders[idx].removeRequest(id: targetID) {
                updatedAt = Date()
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func appendRequest(_ request: APIRequestItem, toFolderID folderID: UUID?) -> Bool {
        guard let folderID else {
            requests.append(request)
            updatedAt = Date()
            return true
        }
        for idx in folders.indices {
            if folders[idx].appendRequest(request, toFolderID: folderID) {
                updatedAt = Date()
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func appendFolder(_ folder: APIFolder, toFolderID parentID: UUID?) -> Bool {
        guard let parentID else {
            folders.append(folder)
            updatedAt = Date()
            return true
        }
        for idx in folders.indices {
            if folders[idx].appendFolder(folder, toFolderID: parentID) {
                updatedAt = Date()
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func removeFolder(id targetID: UUID) -> Bool {
        if let idx = folders.firstIndex(where: { $0.id == targetID }) {
            folders.remove(at: idx)
            updatedAt = Date()
            return true
        }
        for idx in folders.indices {
            if folders[idx].removeFolder(id: targetID) {
                updatedAt = Date()
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func renameFolder(id targetID: UUID, newName: String) -> Bool {
        for idx in folders.indices {
            if folders[idx].renameFolder(id: targetID, newName: newName) {
                updatedAt = Date()
                return true
            }
        }
        return false
    }

    public mutating func setVariable(key: String, value: String) {
        if let idx = variables.firstIndex(where: { $0.key == key }) {
            variables[idx].value = value
            variables[idx].isEnabled = true
        } else {
            variables.append(APIKeyValueItem(key: key, value: value))
        }
        updatedAt = Date()
    }
}

public struct APIEnvironmentVariable: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var key: String
    /// Shared/default value exported to teammates (when not secret).
    public var initialValue: String
    /// Local override value used during execution (takes precedence over `initialValue`).
    public var currentValue: String
    public var isEnabled: Bool
    public var isSecret: Bool

    public init(
        id: UUID = UUID(),
        key: String = "",
        initialValue: String = "",
        currentValue: String? = nil,
        isEnabled: Bool = true,
        isSecret: Bool = false
    ) {
        self.id = id
        self.key = key
        self.initialValue = initialValue
        self.currentValue = currentValue ?? initialValue
        self.isEnabled = isEnabled
        self.isSecret = isSecret
    }

    public var effectiveValue: String {
        currentValue.isEmpty ? initialValue : currentValue
    }
}

public struct APIEnvironment: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sourceFormat: APISourceFormat
    public var variables: [APIEnvironmentVariable]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "Default Environment",
        sourceFormat: APISourceFormat = .ceptra,
        variables: [APIEnvironmentVariable] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sourceFormat = sourceFormat
        self.variables = variables
        self.updatedAt = updatedAt
    }

    public mutating func setVariable(key: String, value: String, isSecret: Bool = false) {
        if let idx = variables.firstIndex(where: { $0.key == key }) {
            variables[idx].currentValue = value
            variables[idx].isEnabled = true
        } else {
            variables.append(APIEnvironmentVariable(key: key, initialValue: isSecret ? "" : value, currentValue: value, isEnabled: true, isSecret: isSecret))
        }
        updatedAt = Date()
    }
}

public struct APICookieItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var attributes: String

    public init(
        id: UUID = UUID(),
        name: String,
        value: String,
        domain: String = "",
        path: String = "/",
        attributes: String = ""
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.attributes = attributes
    }
}

public struct APIAssertionResult: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let passed: Bool
    public let expected: String?
    public let actual: String?
    public let message: String?

    public init(
        id: UUID = UUID(),
        title: String,
        passed: Bool,
        expected: String? = nil,
        actual: String? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.title = title
        self.passed = passed
        self.expected = expected
        self.actual = actual
        self.message = message
    }
}

public struct APIExecutionResult: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let requestID: UUID
    public let requestName: String
    public let folderPath: String
    public let method: APIHTTPMethod
    public let resolvedURL: String
    public let requestHeaders: [String: String]
    public let requestBody: String?
    public let statusCode: Int?
    public let statusText: String?
    public let responseHeaders: [APIKeyValueItem]
    public let cookies: [APICookieItem]
    public let responseBody: String
    public let prettyResponseBody: String
    public let responseBodyByteCount: Int
    public let isBinaryResponse: Bool
    public let durationMs: Int
    public let timings: TimeTravelNetworkTimings?
    public let assertionResults: [APIAssertionResult]
    public let extractedVariables: [String: String]
    public let errorMessage: String?
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        requestName: String,
        folderPath: String = "",
        method: APIHTTPMethod,
        resolvedURL: String,
        requestHeaders: [String: String] = [:],
        requestBody: String? = nil,
        statusCode: Int? = nil,
        statusText: String? = nil,
        responseHeaders: [APIKeyValueItem] = [],
        cookies: [APICookieItem] = [],
        responseBody: String = "",
        prettyResponseBody: String = "",
        responseBodyByteCount: Int = 0,
        isBinaryResponse: Bool = false,
        durationMs: Int = 0,
        timings: TimeTravelNetworkTimings? = nil,
        assertionResults: [APIAssertionResult] = [],
        extractedVariables: [String: String] = [:],
        errorMessage: String? = nil,
        startedAt: Date = Date(),
        finishedAt: Date = Date()
    ) {
        self.id = id
        self.requestID = requestID
        self.requestName = requestName
        self.folderPath = folderPath
        self.method = method
        self.resolvedURL = resolvedURL
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.statusText = statusText
        self.responseHeaders = responseHeaders
        self.cookies = cookies
        self.responseBody = responseBody
        self.prettyResponseBody = prettyResponseBody
        self.responseBodyByteCount = responseBodyByteCount
        self.isBinaryResponse = isBinaryResponse
        self.durationMs = durationMs
        self.timings = timings
        self.assertionResults = assertionResults
        self.extractedVariables = extractedVariables
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var allAssertionsPassed: Bool {
        assertionResults.allSatisfy(\.passed)
    }

    public var isSuccess: Bool {
        guard errorMessage == nil else { return false }
        if !assertionResults.isEmpty {
            return allAssertionsPassed
        }
        guard let statusCode else { return false }
        return (200..<400).contains(statusCode)
    }
}

public struct APICollectionRunSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let collectionID: UUID
    public let collectionName: String
    public let environmentName: String?
    public let startedAt: Date
    public let finishedAt: Date
    public let results: [APIExecutionResult]

    public init(
        id: UUID = UUID(),
        collectionID: UUID,
        collectionName: String,
        environmentName: String? = nil,
        startedAt: Date,
        finishedAt: Date,
        results: [APIExecutionResult]
    ) {
        self.id = id
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.environmentName = environmentName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.results = results
    }

    public var passedCount: Int { results.filter(\.isSuccess).count }
    public var failedCount: Int { results.filter { !$0.isSuccess }.count }
    public var totalDurationMs: Int { results.reduce(0) { $0 + $1.durationMs } }
    public var totalAssertionsPassed: Int { results.flatMap(\.assertionResults).filter(\.passed).count }
    public var totalAssertionsFailed: Int { results.flatMap(\.assertionResults).filter { !$0.passed }.count }

    /// Converts this API Collection Run into Ceptra's native Time-Travel Replay Report & Trace Bundle
    /// so users can inspect it in Replay Inspector or export a standalone interactive HTML Replay report.
    public func toTimeTravelReport(projectPath: String, projectName: String) -> (TestRunReport, TimeTravelTraceBundle) {
        let sensitiveHeaderRegex = try? NSRegularExpression(
            pattern: "^(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key|x-auth-token|x-access-token)$",
            options: [.caseInsensitive]
        )

        func redact(_ headers: [String: String]) -> [String: String] {
            var out: [String: String] = [:]
            for (k, v) in headers {
                let range = NSRange(location: 0, length: (k as NSString).length)
                if sensitiveHeaderRegex?.firstMatch(in: k, range: range) != nil {
                    out[k] = "[REDACTED]"
                } else {
                    out[k] = v
                }
            }
            return out
        }

        let scenarios: [ExecutedScenarioRecord] = results.map { res in
            let reqID = UUID().uuidString
            var resHeaderDict: [String: String] = [:]
            for h in res.responseHeaders {
                resHeaderDict[h.key] = h.value
            }

            let netEntry = TimeTravelNetworkEntry(
                id: reqID,
                method: res.method.rawValue,
                url: res.resolvedURL,
                resourceType: "api",
                source: "rest",
                status: res.statusCode,
                statusText: res.statusText,
                startedAt: res.startedAt,
                durationMs: res.durationMs,
                requestSizeBytes: res.requestBody?.utf8.count,
                responseSizeBytes: res.responseBodyByteCount,
                timings: res.timings,
                requestHeaders: redact(res.requestHeaders),
                responseHeaders: redact(resHeaderDict),
                requestBody: res.requestBody,
                responseBody: res.isBinaryResponse ? nil : res.responseBody,
                errorText: res.errorMessage
            )

            var steps: [ExecutedStepRecord] = [
                ExecutedStepRecord(
                    text: "\(res.method.rawValue) \(res.resolvedURL)",
                    depth: 0,
                    status: (res.errorMessage == nil && (res.statusCode ?? 500) < 500) ? .passed : .failed,
                    durationMs: res.durationMs,
                    startedAt: res.startedAt,
                    finishedAt: res.finishedAt,
                    errorMessage: res.errorMessage,
                    diagnostics: TimeTravelStepDiagnostics(networkRequests: [netEntry])
                )
            ]

            for assertion in res.assertionResults {
                steps.append(ExecutedStepRecord(
                    text: assertion.title,
                    depth: 0,
                    status: assertion.passed ? .passed : .failed,
                    durationMs: 0,
                    startedAt: res.finishedAt,
                    finishedAt: res.finishedAt,
                    errorMessage: assertion.passed ? nil : (assertion.message ?? "Assertion failed"),
                    diagnostics: TimeTravelStepDiagnostics(
                        assertion: TimeTravelAssertionRecord(
                            method: assertion.title,
                            passed: assertion.passed,
                            expected: assertion.expected,
                            actual: assertion.actual,
                            message: assertion.message,
                            relatedRequestId: reqID
                        )
                    )
                ))
            }

            let feature = res.folderPath.isEmpty ? collectionName : "\(collectionName) › \(res.folderPath)"
            let firstFailure = res.errorMessage ?? res.assertionResults.first(where: { !$0.passed })?.message
            return ExecutedScenarioRecord(
                featureTitle: feature,
                scenarioTitle: res.requestName,
                status: res.isSuccess ? .passed : .failed,
                durationMs: res.durationMs,
                startedAt: res.startedAt,
                finishedAt: res.finishedAt,
                tags: ["@api"],
                steps: steps,
                errorMessage: firstFailure
            )
        }

        let summaryLine = "\(collectionName): \(passedCount) passed, \(failedCount) failed in \(totalDurationMs)ms"
        let report = TestRunReport(
            projectPath: projectPath,
            projectName: projectName,
            label: "API Collection · \(collectionName)",
            commandLine: "Ceptra API Studio · \(collectionName)" + (environmentName.map { " (\($0))" } ?? ""),
            startedAt: startedAt,
            finishedAt: finishedAt,
            exitCode: failedCount == 0 ? 0 : 1,
            passedCount: passedCount,
            failedCount: failedCount,
            skippedCount: 0,
            durationMs: totalDurationMs,
            scenarios: scenarios,
            rawOutput: summaryLine
        )
        let bundle = TimeTravelTraceBundle(reportID: report.id, scenarios: scenarios)
        return (report, bundle)
    }
}

public struct APIStudioWorkspaceData: Codable, Equatable, Sendable {
    public var version: Int
    public var collections: [APICollection]
    public var environments: [APIEnvironment]
    public var activeEnvironmentID: UUID?

    public init(
        version: Int = 1,
        collections: [APICollection] = [],
        environments: [APIEnvironment] = [],
        activeEnvironmentID: UUID? = nil
    ) {
        self.version = version
        self.collections = collections
        self.environments = environments
        self.activeEnvironmentID = activeEnvironmentID
    }
}

public struct APIImportOutcome: Sendable {
    public let detectedFormat: APISourceFormat
    public let collections: [APICollection]
    public let environments: [APIEnvironment]
    public let warnings: [String]

    public init(
        detectedFormat: APISourceFormat,
        collections: [APICollection] = [],
        environments: [APIEnvironment] = [],
        warnings: [String] = []
    ) {
        self.detectedFormat = detectedFormat
        self.collections = collections
        self.environments = environments
        self.warnings = warnings
    }
}
