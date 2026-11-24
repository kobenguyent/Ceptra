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
        let compact = lower.replacingOccurrences(of: "_", with: "")
        if (lower == "step" && (lowerActor == "test" || lowerActor == "flow"))
            || ["retryto", "tryto", "within", "session", "eachelement", "pause", "runonios", "runonandroid", "runonweb"].contains(compact) {
            return .control
        }
        if lowerActor == "expect" || lowerActor == "assert"
            || compact.hasPrefix("see") || compact.hasPrefix("dontsee")
            || compact.hasPrefix("expect") || compact.hasPrefix("assert")
            || compact.hasPrefix("tobe") || compact.hasPrefix("tohave")
            || compact.hasPrefix("tocontain") || compact.hasPrefix("toequal")
            || compact.hasPrefix("tomatch") || compact.hasPrefix("tothrow")
            || compact.hasPrefix("topass") || compact.contains("responsecode")
            || compact.contains("responsecontains") || compact.contains("responsevalid") {
            return .assertion
        }
        if lowerActor == "request" || lowerActor.contains("api_request") || lowerActor.contains("apirequest")
            || compact.hasPrefix("send") || compact.contains("request")
            || compact.contains("graphql") || compact.contains("bearer")
            || compact.contains("header") || compact.contains("mutation")
            || compact.contains("query") || compact == "route"
            || compact == "unroute" || compact == "fetch"
            || compact == "waitforresponse" || compact == "waitforrequest"
            || (["get", "post", "put", "patch", "delete", "head"].contains(compact) && lowerActor != "dict") {
            return .network
        }
        if compact.hasPrefix("amon") || compact == "goto" || compact == "reload"
            || compact == "goback" || compact == "goforward" || compact == "setviewportsize"
            || compact.contains("url") || compact.contains("refresh") || compact.contains("back")
            || compact.contains("tab") || compact.contains("switch")
            || ["launchapp", "closeapp", "installapp", "removeapp"].contains(compact) {
            return .navigation
        }
        if compact.hasPrefix("wait") || compact.hasPrefix("retry") {
            return .wait
        }
        if compact.contains("click") || compact.contains("tap") || compact.contains("swipe")
            || compact.contains("fill") || compact.contains("type")
            || compact.contains("press") || compact.contains("check") || compact.contains("select")
            || compact.contains("attach") || compact.contains("drag") || compact.contains("scroll")
            || compact.contains("hover") || compact.contains("clear") || compact.contains("focus")
            || compact.hasPrefix("getby") || compact == "locator"
            || compact == "dblclick" || compact == "uncheck" || compact == "setinputfiles"
            || compact == "screenshot" || compact == "setorientation" {
            return .interaction
        }
        if ["retryto", "tryto", "within", "session", "eachelement", "pause"].contains(compact) {
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

    /// Only CodeceptJS JS/TS test suites and Gherkin `.feature` files that actually declare
    /// `Feature(...)` / `Scenario(...)` (or Gherkin `Feature:` / `Scenario:`) are executable.
    public var isExecutableTestFile: Bool {
        (category == .testSuite || category == .gherkinFeature) && !features.isEmpty
    }

    public var languageHint: String {
        switch fileExtension.lowercased() {
        case "ts", "mts", "cts", "tsx": return "typescript"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "py", "pyi": return "python"
        case "feature": return "gherkin"
        case "json", "jsonc": return "json"
        case "xml", "plist", "svg", "html", "htm": return "xml"
        case "md", "markdown": return "markdown"
        case "yml", "yaml": return "yaml"
        case "toml", "ini", "cfg": return "yaml"
        case "sh", "bash", "zsh": return "shell"
        default: return "plaintext"
        }
    }

    public static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "icns", "tiff",
        "pdf", "zip", "gz", "tgz", "tar", "7z", "rar", "dmg", "pkg", "ipa",
        "mp4", "webm", "mov", "avi", "mp3", "wav", "m4a",
        "woff", "woff2", "ttf", "otf", "eot",
        "sqlite", "db", "bin", "exe", "dll", "so", "dylib", "node", "wasm"
    ]

    public var isBinaryFile: Bool {
        Self.binaryExtensions.contains(fileExtension.lowercased())
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
