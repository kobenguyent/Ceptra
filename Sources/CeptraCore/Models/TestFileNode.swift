import Foundation

public enum WorkspaceFileCategory: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case testSuite
    case gherkinFeature
    case pageObject
    case stepDefinition
    case helper
    case config
    case other

    public var displayTitle: String {
        switch self {
        case .testSuite: return "Test Suites"
        case .gherkinFeature: return "Gherkin Features"
        case .pageObject: return "Page & Step Objects"
        case .stepDefinition: return "Step Definitions"
        case .helper: return "Helpers"
        case .config: return "Configuration"
        case .other: return "Project Files"
        }
    }

    public var symbolName: String {
        switch self {
        case .testSuite: return "checkmark.seal"
        case .gherkinFeature: return "doc.text.magnifyingglass"
        case .pageObject: return "rectangle.stack"
        case .stepDefinition: return "list.bullet.indent"
        case .helper: return "wrench.and.screwdriver"
        case .config: return "gearshape"
        case .other: return "doc.plaintext"
        }
    }
}

public enum StepCategory: String, Codable, Equatable, Hashable, Sendable {
    case navigation
    case interaction
    case assertion
    case network
    case wait
    case control
    case gherkin
    case custom

    public var symbolName: String {
        switch self {
        case .navigation: return "safari"
        case .interaction: return "cursorarrow.click"
        case .assertion: return "checkmark.shield"
        case .network: return "network"
        case .wait: return "clock"
        case .control: return "arrow.triangle.branch"
        case .gherkin: return "text.quote"
        case .custom: return "bolt.horizontal"
        }
    }
}

public struct ParsedStep: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let actor: String
    public let action: String
    public let argumentsSummary: String
    public let rawText: String
    public let lineNumber: Int
    public let category: StepCategory

    public init(
        id: String? = nil,
        actor: String,
        action: String,
        argumentsSummary: String,
        rawText: String,
        lineNumber: Int,
        category: StepCategory
    ) {
        self.id = id ?? "\(lineNumber):\(actor).\(action)"
        self.actor = actor
        self.action = action
        self.argumentsSummary = argumentsSummary
        self.rawText = rawText
        self.lineNumber = lineNumber
        self.category = category
    }

    public static func classify(actor: String, action: String) -> StepCategory {
        let lowerActor = actor.lowercased()
        if ["given", "when", "then", "and", "but"].contains(lowerActor) {
            return .gherkin
        }
        let lower = action.lowercased()
        if lower.hasPrefix("amon") || lower.contains("url") || lower.contains("refresh") || lower.contains("back") || lower.contains("tab") || lower.contains("switch") {
            return .navigation
        }
        if lower.hasPrefix("see") || lower.hasPrefix("dontsee") || lower.hasPrefix("expect") || lower.hasPrefix("assert") || lower.contains("responsecode") || lower.contains("responsecontains") || lower.contains("responsevalid") {
            return .assertion
        }
        if lower.hasPrefix("send") || lower.contains("request") || lower.contains("graphql") || lower.contains("bearer") || lower.contains("header") || lower.contains("mutation") || lower.contains("query") {
            return .network
        }
        if lower.hasPrefix("wait") || lower.hasPrefix("retry") {
            return .wait
        }
        if lower.contains("click") || lower.contains("fill") || lower.contains("type") || lower.contains("press") || lower.contains("check") || lower.contains("select") || lower.contains("attach") || lower.contains("drag") || lower.contains("scroll") || lower.contains("hover") || lower.contains("clear") || lower.contains("focus") {
            return .interaction
        }
        if ["retryto", "tryto", "within", "session", "eachelement", "pause"].contains(lower) {
            return .control
        }
        return .custom
    }
}

public enum ScenarioModifier: String, Codable, Equatable, Hashable, Sendable {
    case standard
    case only
    case skip
    case todo
    case dataDriven
    case outline
}

public struct ParsedScenario: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let cleanTitle: String
    public let filePath: String
    public let featureTitle: String
    public let lineNumber: Int
    public let endLineNumber: Int
    public let tags: [String]
    public let modifier: ScenarioModifier
    public let steps: [ParsedStep]

    public init(
        id: String? = nil,
        title: String,
        filePath: String,
        featureTitle: String,
        lineNumber: Int,
        endLineNumber: Int,
        tags: [String] = [],
        modifier: ScenarioModifier = .standard,
        steps: [ParsedStep] = []
    ) {
        self.id = id ?? "\(filePath)#\(lineNumber):\(title)"
        self.title = title
        self.cleanTitle = ParsedScenario.stripTags(from: title)
        self.filePath = filePath
        self.featureTitle = featureTitle
        self.lineNumber = lineNumber
        self.endLineNumber = endLineNumber
        self.tags = tags
        self.modifier = modifier
        self.steps = steps
    }

    public static func stripTags(from title: String) -> String {
        let parts = title.split(separator: " ").filter { !$0.hasPrefix("@") }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? title : joined
    }
}

public struct ParsedHook: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let kind: String // BeforeSuite, Before, After, AfterSuite, Background
    public let lineNumber: Int
    public let steps: [ParsedStep]

    public init(kind: String, lineNumber: Int, steps: [ParsedStep] = []) {
        self.id = "\(kind):\(lineNumber)"
        self.kind = kind
        self.lineNumber = lineNumber
        self.steps = steps
    }
}

public struct ParsedFeature: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let filePath: String
    public let lineNumber: Int
    public let tags: [String]
    public let hooks: [ParsedHook]
    public let scenarios: [ParsedScenario]

    public init(
        id: String? = nil,
        title: String,
        filePath: String,
        lineNumber: Int,
        tags: [String] = [],
        hooks: [ParsedHook] = [],
        scenarios: [ParsedScenario] = []
    ) {
        self.id = id ?? "\(filePath)#feature:\(lineNumber):\(title)"
        self.title = title
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.tags = tags
        self.hooks = hooks
        self.scenarios = scenarios
    }
}

public struct WorkspaceFile: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let relativePath: String
    public let name: String
    public let fileExtension: String
    public let category: WorkspaceFileCategory
    public let features: [ParsedFeature]

    public init(
        path: String,
        relativePath: String,
        name: String,
        fileExtension: String,
        category: WorkspaceFileCategory,
        features: [ParsedFeature] = []
    ) {
        self.path = path
        self.relativePath = relativePath
        self.name = name
        self.fileExtension = fileExtension
        self.category = category
        self.features = features
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    public var languageHint: String {
        switch fileExtension.lowercased() {
        case "ts", "mts", "cts": return "typescript"
        case "js", "mjs", "cjs": return "javascript"
        case "feature": return "gherkin"
        case "json": return "json"
        case "xml": return "xml"
        case "md": return "markdown"
        default: return "javascript"
        }
    }

    public var allTags: [String] {
        var set = Set<String>()
        for feature in features {
            set.formUnion(feature.tags)
            for scenario in feature.scenarios {
                set.formUnion(scenario.tags)
            }
        }
        return set.sorted()
    }
}
