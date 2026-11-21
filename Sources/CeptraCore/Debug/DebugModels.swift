import Foundation

public enum ExceptionBreakMode: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case none = "none"
    case uncaught = "uncaught"
    case all = "all"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "Off"
        case .uncaught: return "Uncaught Exceptions"
        case .all: return "All Exceptions"
        }
    }
}

public struct DebugLaunchOptions: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var headedBrowser: Bool
    public var breakOnExceptions: ExceptionBreakMode

    public init(
        enabled: Bool = false,
        headedBrowser: Bool = true,
        breakOnExceptions: ExceptionBreakMode = .none
    ) {
        self.enabled = enabled
        self.headedBrowser = headedBrowser
        self.breakOnExceptions = breakOnExceptions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.headedBrowser = try c.decodeIfPresent(Bool.self, forKey: .headedBrowser) ?? true
        self.breakOnExceptions = try c.decodeIfPresent(ExceptionBreakMode.self, forKey: .breakOnExceptions) ?? .none
    }
}

public struct DebugBreakpoint: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let filePath: String
    public var line: Int // 1-based line number
    public var isEnabled: Bool
    public var condition: String?
    public var logMessage: String?

    public init(
        id: UUID = UUID(),
        filePath: String,
        line: Int,
        isEnabled: Bool = true,
        condition: String? = nil,
        logMessage: String? = nil
    ) {
        self.id = id
        self.filePath = URL(fileURLWithPath: filePath).standardizedFileURL.path
        self.line = max(1, line)
        self.isEnabled = isEnabled
        let trimmedCond = condition?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.condition = (trimmedCond?.isEmpty == false) ? trimmedCond : nil
        let trimmedLog = logMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.logMessage = (trimmedLog?.isEmpty == false) ? trimmedLog : nil
    }

    public var isLogpoint: Bool { logMessage != nil }
    public var isConditional: Bool { condition != nil && logMessage == nil }

    /// Converts a logpoint or conditional breakpoint into a V8 CDP condition expression.
    /// Logpoints evaluate `console.log(...)` and return `false` so V8 logs without pausing.
    public var effectiveCDPCondition: String? {
        if let log = logMessage, !log.isEmpty {
            let escaped = Self.buildLogpointExpression(from: log)
            return "(console.log(\(escaped)), false)"
        }
        return condition
    }

    public static func buildLogpointExpression(from template: String) -> String {
        // Supports `{expr}` interpolation inside logpoint messages, e.g. "user={user.id}"
        var parts: [String] = []
        var currentLiteral = ""
        var index = template.startIndex

        func flushLiteral() {
            if !currentLiteral.isEmpty {
                if let encoded = try? JSONEncoder().encode(currentLiteral),
                   let str = String(data: encoded, encoding: .utf8) {
                    parts.append(str)
                }
                currentLiteral = ""
            }
        }

        while index < template.endIndex {
            let ch = template[index]
            if ch == "{" {
                if let closeIdx = template[template.index(after: index)...].firstIndex(of: "}") {
                    let expr = String(template[template.index(after: index)..<closeIdx])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !expr.isEmpty {
                        flushLiteral()
                        parts.append("(\(expr))")
                        index = template.index(after: closeIdx)
                        continue
                    }
                }
            }
            currentLiteral.append(ch)
            index = template.index(after: index)
        }
        flushLiteral()

        if parts.isEmpty {
            return "\"\""
        }
        return parts.joined(separator: ", ")
    }
}

public enum DebugSessionPhase: Equatable, Sendable {
    case idle
    case launching
    case running
    case paused(reason: String)
    case interactiveShell
    case stopping

    public var isActive: Bool {
        self != .idle
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

public struct DebugSourceLocation: Equatable, Hashable, Sendable {
    public let filePath: String
    public let line: Int // 1-based
    public let column: Int // 1-based
    public let scriptId: String

    public init(filePath: String, line: Int, column: Int = 1, scriptId: String = "") {
        self.filePath = filePath
        self.line = max(1, line)
        self.column = max(1, column)
        self.scriptId = scriptId
    }

    public var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

public struct DebugScope: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let type: String // local, closure, block, script, global, with, catch
    public let name: String
    public let objectId: String

    public init(type: String, name: String?, objectId: String) {
        self.id = "\(type):\(objectId)"
        self.type = type
        self.name = (name?.isEmpty == false) ? name! : type.capitalized
        self.objectId = objectId
    }
}

public struct DebugCallFrame: Identifiable, Equatable, Hashable, Sendable {
    public let id: String // CDP callFrameId
    public let functionName: String
    public let location: DebugSourceLocation
    public let scopes: [DebugScope]
    public let thisObjectId: String?
    public let isInternal: Bool

    public init(
        id: String,
        functionName: String,
        location: DebugSourceLocation,
        scopes: [DebugScope],
        thisObjectId: String?,
        isInternal: Bool
    ) {
        self.id = id
        self.functionName = functionName.isEmpty ? "(anonymous)" : functionName
        self.location = location
        self.scopes = scopes
        self.thisObjectId = thisObjectId
        self.isInternal = isInternal
    }
}

public struct DebugVariable: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let value: String
    public let type: String
    public let subtype: String?
    public let className: String?
    public let objectId: String?

    public var isExpandable: Bool {
        guard objectId != nil else { return false }
        return type == "object" && subtype != "null"
    }

    public init(
        name: String,
        value: String,
        type: String,
        subtype: String? = nil,
        className: String? = nil,
        objectId: String? = nil
    ) {
        self.id = "\(name)::\(objectId ?? value)"
        self.name = name
        self.value = value
        self.type = type
        self.subtype = subtype
        self.className = className
        self.objectId = objectId
    }
}

public struct DebugWatchItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var expression: String
    public var value: String
    public var type: String
    public var isError: Bool
    public var objectId: String?

    public init(
        id: UUID = UUID(),
        expression: String,
        value: String = "not available",
        type: String = "undefined",
        isError: Bool = false,
        objectId: String? = nil
    ) {
        self.id = id
        self.expression = expression
        self.value = value
        self.type = type
        self.isError = isError
        self.objectId = objectId
    }
}

public struct DebugEvalResult: Equatable, Sendable {
    public let expression: String
    public let value: String
    public let type: String
    public let isError: Bool
    public let objectId: String?

    public init(
        expression: String,
        value: String,
        type: String,
        isError: Bool = false,
        objectId: String? = nil
    ) {
        self.expression = expression
        self.value = value
        self.type = type
        self.isError = isError
        self.objectId = objectId
    }
}

public struct DebugConsoleEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let expression: String
    public let result: String
    public let isError: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        expression: String,
        result: String,
        isError: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.expression = expression
        self.result = result
        self.isError = isError
    }
}
