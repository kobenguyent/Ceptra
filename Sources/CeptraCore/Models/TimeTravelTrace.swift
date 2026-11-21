import Foundation

public struct TimeTravelBoundingBox: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let viewportWidth: Double?
    public let viewportHeight: Double?

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        viewportWidth: Double? = nil,
        viewportHeight: Double? = nil
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }
}

public struct TimeTravelDOMSnapshot: Codable, Equatable, Hashable, Sendable {
    public let html: String
    public let url: String?
    public let title: String?
    public let targetSelector: String?
    public let targetOuterHTML: String?
    public let targetBoundingBox: TimeTravelBoundingBox?
    public let matchedCount: Int?

    public init(
        html: String,
        url: String? = nil,
        title: String? = nil,
        targetSelector: String? = nil,
        targetOuterHTML: String? = nil,
        targetBoundingBox: TimeTravelBoundingBox? = nil,
        matchedCount: Int? = nil
    ) {
        self.html = html
        self.url = url
        self.title = title
        self.targetSelector = targetSelector
        self.targetOuterHTML = targetOuterHTML
        self.targetBoundingBox = targetBoundingBox
        self.matchedCount = matchedCount
    }
}

public struct TimeTravelNetworkTimings: Codable, Equatable, Hashable, Sendable {
    public let dnsMs: Int?
    public let connectMs: Int?
    public let tlsMs: Int?
    public let ttfbMs: Int?
    public let downloadMs: Int?
    public let totalMs: Int?

    public init(
        dnsMs: Int? = nil,
        connectMs: Int? = nil,
        tlsMs: Int? = nil,
        ttfbMs: Int? = nil,
        downloadMs: Int? = nil,
        totalMs: Int? = nil
    ) {
        self.dnsMs = dnsMs
        self.connectMs = connectMs
        self.tlsMs = tlsMs
        self.ttfbMs = ttfbMs
        self.downloadMs = downloadMs
        self.totalMs = totalMs
    }
}

public struct TimeTravelAssertionRecord: Codable, Equatable, Hashable, Sendable {
    public let method: String
    public let passed: Bool
    public let expected: String?
    public let actual: String?
    public let message: String?
    public let relatedRequestId: String?

    public init(
        method: String,
        passed: Bool,
        expected: String? = nil,
        actual: String? = nil,
        message: String? = nil,
        relatedRequestId: String? = nil
    ) {
        self.method = method
        self.passed = passed
        self.expected = expected
        self.actual = actual
        self.message = message
        self.relatedRequestId = relatedRequestId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.method = try c.decodeIfPresent(String.self, forKey: .method) ?? "assert"
        self.passed = try c.decodeIfPresent(Bool.self, forKey: .passed) ?? true
        self.expected = try c.decodeIfPresent(String.self, forKey: .expected)
        self.actual = try c.decodeIfPresent(String.self, forKey: .actual)
        self.message = try c.decodeIfPresent(String.self, forKey: .message)
        self.relatedRequestId = try c.decodeIfPresent(String.self, forKey: .relatedRequestId)
    }
}

public struct TimeTravelNetworkEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let method: String
    public let url: String
    public let resourceType: String?
    public let source: String?
    public let status: Int?
    public let statusText: String?
    public let startedAt: Date?
    public let durationMs: Int?
    public let requestSizeBytes: Int?
    public let responseSizeBytes: Int?
    public let timings: TimeTravelNetworkTimings?
    public let requestHeaders: [String: String]
    public let responseHeaders: [String: String]
    public let requestBody: String?
    public let responseBody: String?
    public let errorText: String?

    public init(
        id: String = UUID().uuidString,
        method: String,
        url: String,
        resourceType: String? = nil,
        source: String? = nil,
        status: Int? = nil,
        statusText: String? = nil,
        startedAt: Date? = nil,
        durationMs: Int? = nil,
        requestSizeBytes: Int? = nil,
        responseSizeBytes: Int? = nil,
        timings: TimeTravelNetworkTimings? = nil,
        requestHeaders: [String: String] = [:],
        responseHeaders: [String: String] = [:],
        requestBody: String? = nil,
        responseBody: String? = nil,
        errorText: String? = nil
    ) {
        self.id = id
        self.method = method
        self.url = url
        self.resourceType = resourceType
        self.source = source
        self.status = status
        self.statusText = statusText
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.requestSizeBytes = requestSizeBytes
        self.responseSizeBytes = responseSizeBytes
        self.timings = timings
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.errorText = errorText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        self.url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.resourceType = try c.decodeIfPresent(String.self, forKey: .resourceType)
        self.source = try c.decodeIfPresent(String.self, forKey: .source)
        self.status = try c.decodeIfPresent(Int.self, forKey: .status)
        self.statusText = try c.decodeIfPresent(String.self, forKey: .statusText)
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        self.durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        self.requestSizeBytes = try c.decodeIfPresent(Int.self, forKey: .requestSizeBytes)
        self.responseSizeBytes = try c.decodeIfPresent(Int.self, forKey: .responseSizeBytes)
        self.timings = try c.decodeIfPresent(TimeTravelNetworkTimings.self, forKey: .timings)
        self.requestHeaders = try c.decodeIfPresent([String: String].self, forKey: .requestHeaders) ?? [:]
        self.responseHeaders = try c.decodeIfPresent([String: String].self, forKey: .responseHeaders) ?? [:]
        self.requestBody = try c.decodeIfPresent(String.self, forKey: .requestBody)
        self.responseBody = try c.decodeIfPresent(String.self, forKey: .responseBody)
        self.errorText = try c.decodeIfPresent(String.self, forKey: .errorText)
    }
}

public enum TimeTravelConsoleLevel: String, Codable, Equatable, Hashable, Sendable {
    case log
    case info
    case warn
    case error
    case debug
    case pageerror

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.lowercased() ?? "log"
        switch raw {
        case "warning", "warn": self = .warn
        case "error": self = .error
        case "pageerror", "uncaught": self = .pageerror
        case "info": self = .info
        case "debug", "trace": self = .debug
        default: self = .log
        }
    }
}

public struct TimeTravelConsoleEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let level: TimeTravelConsoleLevel
    public let message: String
    public let timestamp: Date?
    public let sourceURL: String?
    public let lineNumber: Int?

    public init(
        id: String = UUID().uuidString,
        level: TimeTravelConsoleLevel,
        message: String,
        timestamp: Date? = nil,
        sourceURL: String? = nil,
        lineNumber: Int? = nil
    ) {
        self.id = id
        self.level = level
        self.message = message
        self.timestamp = timestamp
        self.sourceURL = sourceURL
        self.lineNumber = lineNumber
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.level = try c.decodeIfPresent(TimeTravelConsoleLevel.self, forKey: .level) ?? .log
        self.message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        self.timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp)
        self.sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        self.lineNumber = try c.decodeIfPresent(Int.self, forKey: .lineNumber)
    }
}

public struct TimeTravelStepDiagnostics: Codable, Equatable, Hashable, Sendable {
    public let pageURL: String?
    public let beforeScreenshotDataURI: String?
    public let afterScreenshotDataURI: String?
    public let domSnapshot: TimeTravelDOMSnapshot?
    public let networkRequests: [TimeTravelNetworkEntry]
    public let consoleEntries: [TimeTravelConsoleEntry]
    public let assertion: TimeTravelAssertionRecord?

    public init(
        pageURL: String? = nil,
        beforeScreenshotDataURI: String? = nil,
        afterScreenshotDataURI: String? = nil,
        domSnapshot: TimeTravelDOMSnapshot? = nil,
        networkRequests: [TimeTravelNetworkEntry] = [],
        consoleEntries: [TimeTravelConsoleEntry] = [],
        assertion: TimeTravelAssertionRecord? = nil
    ) {
        self.pageURL = pageURL
        self.beforeScreenshotDataURI = beforeScreenshotDataURI
        self.afterScreenshotDataURI = afterScreenshotDataURI
        self.domSnapshot = domSnapshot
        self.networkRequests = networkRequests
        self.consoleEntries = consoleEntries
        self.assertion = assertion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pageURL = try c.decodeIfPresent(String.self, forKey: .pageURL)
        self.beforeScreenshotDataURI = try c.decodeIfPresent(String.self, forKey: .beforeScreenshotDataURI)
        self.afterScreenshotDataURI = try c.decodeIfPresent(String.self, forKey: .afterScreenshotDataURI)
        self.domSnapshot = try c.decodeIfPresent(TimeTravelDOMSnapshot.self, forKey: .domSnapshot)
        self.networkRequests = try c.decodeIfPresent([TimeTravelNetworkEntry].self, forKey: .networkRequests) ?? []
        self.consoleEntries = try c.decodeIfPresent([TimeTravelConsoleEntry].self, forKey: .consoleEntries) ?? []
        self.assertion = try c.decodeIfPresent(TimeTravelAssertionRecord.self, forKey: .assertion)
    }

    public var hasWebVisuals: Bool {
        beforeScreenshotDataURI != nil || afterScreenshotDataURI != nil || domSnapshot != nil
    }

    public var hasApiTraffic: Bool {
        !networkRequests.isEmpty || assertion != nil
    }

    public var isEmpty: Bool {
        beforeScreenshotDataURI == nil &&
            afterScreenshotDataURI == nil &&
            domSnapshot == nil &&
            networkRequests.isEmpty &&
            consoleEntries.isEmpty &&
            assertion == nil
    }
}

public struct TimeTravelTraceBundle: Codable, Equatable, Sendable {
    public let version: Int
    public let reportID: UUID
    public let scenarios: [ExecutedScenarioRecord]
    public let createdAt: Date

    public init(
        version: Int = 1,
        reportID: UUID,
        scenarios: [ExecutedScenarioRecord],
        createdAt: Date = Date()
    ) {
        self.version = version
        self.reportID = reportID
        self.scenarios = scenarios
        self.createdAt = createdAt
    }
}
