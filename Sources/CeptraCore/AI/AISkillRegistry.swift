import Foundation

public enum AISkillSource: String, Codable, Equatable, Hashable, Sendable {
    case builtIn
    case workspace
    case userGlobal

    public var badgeLabel: String {
        switch self {
        case .builtIn: return "Built-in"
        case .workspace: return "Project"
        case .userGlobal: return "Global"
        }
    }

    public var sectionTitle: String {
        switch self {
        case .builtIn: return "BUILT-IN CODECEPTJS COMMANDS"
        case .workspace: return "PROJECT SKILLS & COMMANDS"
        case .userGlobal: return "PERSONAL GLOBAL SKILLS"
        }
    }

    public var sortRank: Int {
        switch self {
        case .workspace: return 0
        case .builtIn: return 1
        case .userGlobal: return 2
        }
    }
}

public struct AISkillDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let slug: String
    public let title: String
    public let description: String
    public let argumentHint: String?
    public let symbolName: String
    public let source: AISkillSource
    public let sourceOriginLabel: String
    public let filePath: String?
    public let builtInBody: String?
    public let recommendedContextKinds: [AIContextAttachmentKind]
    public let userInvocable: Bool
    public let isMetaBrowseCommand: Bool

    public init(
        id: String? = nil,
        slug: String,
        title: String,
        description: String,
        argumentHint: String? = nil,
        symbolName: String = "slash.circle",
        source: AISkillSource,
        sourceOriginLabel: String,
        filePath: String? = nil,
        builtInBody: String? = nil,
        recommendedContextKinds: [AIContextAttachmentKind] = [],
        userInvocable: Bool = true,
        isMetaBrowseCommand: Bool = false
    ) {
        self.id = id ?? "\(source.rawValue):\(slug)"
        self.slug = slug
        self.title = title
        self.description = description
        self.argumentHint = argumentHint
        self.symbolName = symbolName
        self.source = source
        self.sourceOriginLabel = sourceOriginLabel
        self.filePath = filePath
        self.builtInBody = builtInBody
        self.recommendedContextKinds = recommendedContextKinds
        self.userInvocable = userInvocable
        self.isMetaBrowseCommand = isMetaBrowseCommand
    }

    public var slashCommand: String {
        "/\(slug)"
    }
}

public struct AISkillInvocation: Equatable, Sendable {
    public let descriptor: AISkillDescriptor
    public let arguments: String
    public let resolvedInstructionBody: String
    public let wasRedacted: Bool
    public let referencedFiles: [String]

    public init(
        descriptor: AISkillDescriptor,
        arguments: String,
        resolvedInstructionBody: String,
        wasRedacted: Bool = false,
        referencedFiles: [String] = []
    ) {
        self.descriptor = descriptor
        self.arguments = arguments
        self.resolvedInstructionBody = resolvedInstructionBody
        self.wasRedacted = wasRedacted
        self.referencedFiles = referencedFiles
    }
}

public struct AISlashQueryMatch: Equatable, Sendable {
    public let query: String
    public let isExactMetaBrowse: Bool

    public init(query: String, isExactMetaBrowse: Bool) {
        self.query = query
        self.isExactMetaBrowse = isExactMetaBrowse
    }
}

public struct AISlashParseResult: Equatable, Sendable {
    public let descriptor: AISkillDescriptor
    public let arguments: String
    public let isMetaBrowse: Bool

    public init(descriptor: AISkillDescriptor, arguments: String, isMetaBrowse: Bool) {
        self.descriptor = descriptor
        self.arguments = arguments
        self.isMetaBrowse = isMetaBrowse
    }
}

public enum AISkillRegistryError: LocalizedError, Equatable, Sendable {
    case blockedSkillPath(String)
    case unreadableSkillFile(String)
    case invalidSlug(String)

    public var errorDescription: String? {
        switch self {
        case .blockedSkillPath(let name):
            return "Blocked reading skill '\(name)' because it resolves outside safe Markdown skill rules."
        case .unreadableSkillFile(let name):
            return "Could not read skill file '\(name)'."
        case .invalidSlug(let raw):
            return "Invalid skill name '\(raw)'. Use letters, numbers, and hyphens (e.g. locator-audit)."
        }
    }
}

/// Universal, machine-independent registry for `/commands` and open-standard `SKILL.md` Agent Skills.
/// Works identically across Local Ollama, Cloud APIs, and CLI Agents by resolving and injecting
/// skill instructions inside Ceptra before provider dispatch.
///
/// Security invariants:
/// - Narrow `.md`-only reader: never opens credential/config files (`.json`, `.env`, `.pem`, `.key`, etc.).
/// - Symlink-resolved validation: allows standard skill symlinks to `.md` files while strictly blocking
///   targets inside sensitive host directories (`~/.ssh`, `~/.aws`, Keychain, `/etc`, etc.).
/// - Zero shell execution: third-party `!`cmd`` backtick directives are neutralized into passive text.
/// - Bounded prompt budgets (`12 KB` skill body + `4 KB` local references) so small local Ollama models remain fast.
public enum AISkillRegistry {
    public static let maxSkillFileBytes = 256 * 1024
    public static let maxSkillBodyChars = 12_000
    public static let maxReferenceExcerptChars = 4_000
    public static let maxDiscoveredSkills = 120

    private static let blockedResolvedHomeSubpaths: [String] = [
        ".ssh", ".aws", ".gnupg", ".kube", ".docker",
        ".config/gh", ".config/gcloud", ".config/op",
        "Library/Keychains", "Library/Cookies", "Library/Mail", "Library/Messages", "Library/Safari",
        "Library/Application Support/Ceptra"
    ]

    private static let blockedSystemPathPrefixes: [String] = [
        "/etc/", "/private/etc/", "/var/db/", "/private/var/db/", "/System/"
    ]

    // MARK: - Built-in CodeceptJS 4.x Commands (Available Out of the Box on Every Mac)

    public static let builtInCommands: [AISkillDescriptor] = [
        AISkillDescriptor(
            slug: "scenario",
            title: "Generate CodeceptJS Scenario",
            description: "Write a clean, idiomatic CodeceptJS 4.x Feature/Scenario matching your project style and I.* steps.",
            argumentHint: "[describe the user flow or scenario goal]",
            symbolName: "wand.and.stars",
            source: .builtIn,
            sourceOriginLabel: "Ceptra",
            builtInBody: """
            Generate a complete, runnable CodeceptJS 4.x `Scenario` (and `Feature` header if creating a new file) using the active helper (`${HELPER}`).

            Requirements:
            1. Match the active file's module format (ESM `import` vs CommonJS) and TypeScript/JavaScript style.
            2. Reuse existing workspace `I.*` custom steps and PageObjects whenever available.
            3. Use resilient semantic locators matching `${HELPER}`: for Web helpers (`Playwright`/`WebDriver`), use `data-testid`, accessible roles/labels, or visible text (avoid brittle nth-child CSS or deep XPath); for `Mobilewright`, use native accessibility locators (`~accessibilityId`, `#id`, `{ role, name }`, `{ android, ios }`, or adjacent field labels — never CSS or XPath).
            4. Avoid arbitrary `I.wait(n)` sleeps; prefer explicit assertions (`I.waitForElement`, `I.waitForVisible`, `I.waitForText`, `I.see`).
            5. Return the final runnable code inside a single clean fenced code block ready for Preview & Apply.

            User goal: $ARGUMENTS
            """,
            recommendedContextKinds: [.activeFile, .codeceptAPI]
        ),
        AISkillDescriptor(
            slug: "fix",
            title: "Harden Locators & Fix Flakiness",
            description: "Replace brittle selectors, race conditions, and hard waits with resilient CodeceptJS 4.x patterns.",
            argumentHint: "[optional failing selector or symptom]",
            symbolName: "wrench.and.screwdriver",
            source: .builtIn,
            sourceOriginLabel: "Ceptra",
            builtInBody: """
            Audit the attached CodeceptJS code (or selection) for flakiness, brittle selectors, race conditions, or assertion gaps, and provide a hardened replacement.

            Checklist:
            1. Replace fragile selectors with semantic locators matching `${HELPER}`: for Web (`[data-testid="..."]`, accessible labels, button text, or strict `locate()` expressions); for `Mobilewright` (`~accessibilityId`, `#id`, `{ role, name }`, `{ android, ios }`, or adjacent field labels — never CSS or XPath).
            2. Replace fixed `I.wait(...)` calls with deterministic waits (`I.waitForVisible`, `I.waitForInvisible`, `I.waitForText`, `I.waitForResponse`, `I.waitInUrl`).
            3. Fix missing `await` on async helper calls (`grabTextFrom`, `grabAttributeFrom`, `grabSource`, `sendGetRequest`, etc.).
            4. Keep changes minimal and preserve test intent. Return the updated code in a fenced code block.

            Focus notes: $ARGUMENTS
            """,
            recommendedContextKinds: [.activeFile, .selection, .consoleErrors, .codeceptAPI]
        ),
        AISkillDescriptor(
            slug: "page-object",
            title: "Extract PageObject",
            description: "Refactor procedural test steps into a reusable CodeceptJS PageObject module.",
            argumentHint: "[PageObject name, e.g. loginPage]",
            symbolName: "rectangle.3.group",
            source: .builtIn,
            sourceOriginLabel: "Ceptra",
            builtInBody: """
            Refactor the attached CodeceptJS test into a clean, maintainable PageObject pattern.

            Deliverables:
            1. Define the PageObject with clear semantic `locators` and intention-revealing action/assertion methods (e.g., `open()`, `submitLogin(...)`, `seeDashboard()`).
            2. Show how to register it in `codecept.conf` (`include: { ... }`) if not already present.
            3. Show the simplified `Scenario` using the injected PageObject (`Scenario('...', async ({ I, pageObject }) => { ... })`).
            4. Match the workspace's JS/TS and CommonJS/ESM conventions.

            Requested PageObject / focus: $ARGUMENTS
            """,
            recommendedContextKinds: [.activeFile, .selection, .codeceptAPI]
        ),
        AISkillDescriptor(
            slug: "debug",
            title: "Debug Failure & Replay Trace",
            description: "Analyze failing Replay DOM snapshots, HTTP 4xx/5xx responses, and console stack traces.",
            argumentHint: "[optional error context]",
            symbolName: "ladybug",
            source: .builtIn,
            sourceOriginLabel: "Ceptra",
            builtInBody: """
            Perform a structured root-cause analysis of the failing CodeceptJS test using the attached Replay trace, DOM snapshot, network errors, and console output.

            Output structure:
            1. **Root Cause:** State the exact reason the step failed (missing element, wrong selector, timing/hydration race, HTTP 4xx/5xx API failure, or assertion mismatch).
            2. **Evidence:** Cite the specific selector, URL, status code, or error line from the attached trace.
            3. **Fix:** Provide the minimal, resilient code fix in a fenced code block ready to apply.

            Additional symptom: $ARGUMENTS
            """,
            recommendedContextKinds: [.activeFile, .replayFailure, .consoleErrors, .codeceptAPI]
        ),
        AISkillDescriptor(
            slug: "explain",
            title: "Explain Test / Code",
            description: "Walk through what the active file or selected lines do, highlighting fixtures and edge cases.",
            argumentHint: "[optional question]",
            symbolName: "doc.text.magnifyingglass",
            source: .builtIn,
            sourceOriginLabel: "Ceptra",
            builtInBody: """
            Explain the attached CodeceptJS file or selection clearly and concisely:
            1. Summarize the Feature/Scenario purpose and test setup (`Before`/`After`, fixtures, PageObjects).
            2. Walk through key steps and assertions in order.
            3. Call out any subtle helper behavior, async pitfalls, or flakiness risks.

            Specific question: $ARGUMENTS
            """,
            recommendedContextKinds: [.activeFile, .selection, .codeceptAPI]
        ),
        AISkillDescriptor(
            slug: "review",
            title: "Audit Test Quality",
            description: "Review tests for locator resilience, assertion strength, test isolation, and CodeceptJS best practices.",
            argumentHint: "[optional review criteria]",
            symbolName: "checkmark.shield",
            source: .builtIn,
            sourceOriginLabel: "Ceptra",
            builtInBody: """
            Review the attached CodeceptJS test file like a senior QA automation architect.

            Evaluate:
            1. **Selector Stability:** Fragile selectors vs semantic locators.
            2. **Assertion Quality:** Are tests verifying real outcomes/state, not just presence?
            3. **Isolation & Determinism:** Shared state leaks, hardcoded credentials/URLs, arbitrary sleeps.
            4. **Actionable Improvements:** Prioritize the top issues (High / Medium / Low) and provide an improved code block if helpful.

            Review focus: $ARGUMENTS
            """,
            recommendedContextKinds: [.activeFile, .selection, .codeceptAPI]
        ),
        AISkillDescriptor(
            slug: "api-test",
            title: "Generate REST API Test",
            description: "Create a CodeceptJS REST + JSONResponse API test scenario with status and payload assertions.",
            argumentHint: "[METHOD /path or endpoint description]",
            symbolName: "network",
            source: .builtIn,
            sourceOriginLabel: "Ceptra",
            builtInBody: """
            Write an idiomatic CodeceptJS 4.x REST API test scenario using the `REST` and `JSONResponse` helpers (`I.sendGetRequest`, `I.sendPostRequest`, `I.seeResponseCodeIs`, `I.seeResponseCodeIsSuccessful`, `I.seeResponseContainsJson`, `I.seeResponseMatchesJsonSchema`).

            Requirements:
            1. Cover the happy path plus key error/validation status codes when appropriate.
            2. Never hardcode real secrets or tokens; read from `process.env` placeholders if auth headers are required.
            3. Output clean runnable code in a single fenced code block.

            Endpoint / API specification: $ARGUMENTS
            """,
            recommendedContextKinds: [.activeFile, .codeceptAPI]
        ),
        AISkillDescriptor(
            slug: "gherkin",
            title: "Convert to/from BDD Gherkin",
            description: "Generate Gherkin .feature scenarios and matching CodeceptJS Given/When/Then step definitions.",
            argumentHint: "[feature story or conversion direction]",
            symbolName: "list.bullet.rectangle",
            source: .builtIn,
            sourceOriginLabel: "Ceptra",
            builtInBody: """
            Convert or generate clean BDD Gherkin (`Feature`, `Background`, `Scenario`, `Scenario Outline` + `Examples`) and matching CodeceptJS step definitions (`Given`, `When`, `Then` using `const { I } = inject()`).

            Requirements:
            1. Write declarative, business-readable Gherkin steps (avoid CSS selectors in `.feature` files).
            2. Keep step definitions concise, parameterized, and reusable.
            3. Return the `.feature` block and step definition block in clearly labeled fenced code blocks.

            Request: $ARGUMENTS
            """,
            recommendedContextKinds: [.activeFile, .codeceptAPI]
        ),
        AISkillDescriptor(
            slug: "skills",
            title: "Browse All Skills & Commands",
            description: "Open the searchable Skills & Commands browser or create a new project SKILL.md.",
            argumentHint: nil,
            symbolName: "sparkles.rectangle.stack",
            source: .builtIn,
            sourceOriginLabel: "Ceptra",
            recommendedContextKinds: [],
            userInvocable: true,
            isMetaBrowseCommand: true
        )
    ]

    // MARK: - Multi-Tier Portable Discovery

    /// Discovers built-in CodeceptJS commands, project workspace skills/commands, and optional
    /// user-global skills in standard cross-tool locations on any macOS machine.
    public static func discoverSkills(
        workspaceRoot: URL?,
        includeGlobalSkills: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [AISkillDescriptor] {
        var bySlug: [String: AISkillDescriptor] = [:]

        // 1. Lowest precedence: User-Global skills/commands (if enabled & directories exist on this Mac)
        if includeGlobalSkills {
            let globalRoots: [(dir: URL, kind: String, origin: String)] = [
                (homeDirectory.appendingPathComponent(".codex/skills", isDirectory: true), "skills", "~/.codex"),
                (homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true), "skills", "~/.claude"),
                (homeDirectory.appendingPathComponent(".claude/commands", isDirectory: true), "commands", "~/.claude"),
                (homeDirectory.appendingPathComponent(".agents/skills", isDirectory: true), "skills", "~/.agents"),
                (homeDirectory.appendingPathComponent(".ceptra/commands", isDirectory: true), "commands", "~/.ceptra"),
                (homeDirectory.appendingPathComponent(".ceptra/skills", isDirectory: true), "skills", "~/.ceptra")
            ]
            for entry in globalRoots {
                let found = entry.kind == "skills"
                    ? scanSkillsDirectory(entry.dir, source: .userGlobal, originLabel: entry.origin, homeDirectory: homeDirectory)
                    : scanCommandsDirectory(entry.dir, source: .userGlobal, originLabel: entry.origin, homeDirectory: homeDirectory)
                for skill in found where skill.userInvocable {
                    bySlug[skill.slug.lowercased()] = skill
                }
            }
        }

        // 2. Middle precedence: Built-in Ceptra CodeceptJS commands (always available on every Mac)
        for builtIn in builtInCommands {
            bySlug[builtIn.slug.lowercased()] = builtIn
        }

        // 3. Highest precedence: Active Project Workspace skills/commands (portable across git clones)
        if let root = workspaceRoot {
            let workspaceRoots: [(dir: URL, kind: String, origin: String)] = [
                (root.appendingPathComponent(".codex/skills", isDirectory: true), "skills", ".codex"),
                (root.appendingPathComponent(".claude/skills", isDirectory: true), "skills", ".claude"),
                (root.appendingPathComponent(".claude/commands", isDirectory: true), "commands", ".claude"),
                (root.appendingPathComponent(".agents/skills", isDirectory: true), "skills", ".agents"),
                (root.appendingPathComponent(".ceptra/commands", isDirectory: true), "commands", ".ceptra"),
                (root.appendingPathComponent(".ceptra/skills", isDirectory: true), "skills", ".ceptra")
            ]
            for entry in workspaceRoots {
                let found = entry.kind == "skills"
                    ? scanSkillsDirectory(entry.dir, source: .workspace, originLabel: entry.origin, homeDirectory: homeDirectory)
                    : scanCommandsDirectory(entry.dir, source: .workspace, originLabel: entry.origin, homeDirectory: homeDirectory)
                for skill in found where skill.userInvocable {
                    // Never allow a workspace skill to hijack the `/skills` meta browser command
                    guard skill.slug.lowercased() != "skills" && skill.slug.lowercased() != "commands" else { continue }
                    bySlug[skill.slug.lowercased()] = skill
                }
            }
        }

        let sorted = bySlug.values.sorted { lhs, rhs in
            if lhs.source.sortRank != rhs.source.sortRank {
                return lhs.source.sortRank < rhs.source.sortRank
            }
            if lhs.isMetaBrowseCommand != rhs.isMetaBrowseCommand {
                return !lhs.isMetaBrowseCommand
            }
            return lhs.slug.localizedCaseInsensitiveCompare(rhs.slug) == .orderedAscending
        }

        return Array(sorted.prefix(maxDiscoveredSkills))
    }

    private static func scanSkillsDirectory(
        _ rootDir: URL,
        source: AISkillSource,
        originLabel: String,
        homeDirectory: URL
    ) -> [AISkillDescriptor] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDir.path),
              let entries = try? fm.contentsOfDirectory(
                  at: rootDir,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var results: [AISkillDescriptor] = []
        for entry in entries {
            let folderName = entry.lastPathComponent
            guard !folderName.hasPrefix(".") else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let skillFile = entry.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fm.fileExists(atPath: skillFile.path),
                  isAllowedSkillMarkdownFile(url: skillFile, homeDirectory: homeDirectory) else { continue }

            guard let descriptor = parseDescriptor(
                fromFileAt: skillFile,
                fallbackSlug: folderName,
                source: source,
                originLabel: originLabel,
                symbolName: source == .workspace ? "sparkles" : "square.stack.3d.up"
            ) else { continue }
            results.append(descriptor)
        }
        return results
    }

    private static func scanCommandsDirectory(
        _ rootDir: URL,
        source: AISkillSource,
        originLabel: String,
        homeDirectory: URL
    ) -> [AISkillDescriptor] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDir.path),
              let entries = try? fm.contentsOfDirectory(
                  at: rootDir,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var results: [AISkillDescriptor] = []
        for entry in entries {
            guard entry.pathExtension.lowercased() == "md",
                  !entry.lastPathComponent.hasPrefix("."),
                  isAllowedSkillMarkdownFile(url: entry, homeDirectory: homeDirectory) else { continue }

            let fallbackSlug = entry.deletingPathExtension().lastPathComponent
            guard let descriptor = parseDescriptor(
                fromFileAt: entry,
                fallbackSlug: fallbackSlug,
                source: source,
                originLabel: originLabel,
                symbolName: "terminal"
            ) else { continue }
            results.append(descriptor)
        }
        return results
    }

    private static func parseDescriptor(
        fromFileAt url: URL,
        fallbackSlug: String,
        source: AISkillSource,
        originLabel: String,
        symbolName: String
    ) -> AISkillDescriptor? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int,
              fileSize > 0, fileSize <= maxSkillFileBytes,
              let data = try? Data(contentsOf: url),
              !data.prefix(2048).contains(0),
              let markdown = String(data: data, encoding: .utf8) else {
            return nil
        }

        let parsed = parseFrontmatterAndBody(markdown: markdown)
        let rawName = parsed.frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = sanitizeSlug(rawName?.isEmpty == false ? rawName! : fallbackSlug)
        guard !slug.isEmpty else { return nil }

        let userInvocable: Bool = {
            if let raw = parsed.frontmatter["user-invocable"]?.lowercased() {
                return raw != "false" && raw != "no" && raw != "0"
            }
            return true
        }()

        let rawDescription = parsed.frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDesc = firstSummaryLine(from: parsed.body) ?? "Custom \(originLabel) skill"
        let description = (rawDescription?.isEmpty == false ? rawDescription! : fallbackDesc)
        let clippedDesc = description.count > 180 ? String(description.prefix(177)) + "…" : description

        let hint = parsed.frontmatter["argument-hint"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHint = (hint?.isEmpty == false) ? hint : nil

        let title = makeDisplayTitle(fromSlug: slug)

        return AISkillDescriptor(
            slug: slug,
            title: title,
            description: clippedDesc,
            argumentHint: cleanHint,
            symbolName: symbolName,
            source: source,
            sourceOriginLabel: originLabel,
            filePath: url.standardizedFileURL.path,
            builtInBody: nil,
            recommendedContextKinds: [.activeFile],
            userInvocable: userInvocable,
            isMetaBrowseCommand: false
        )
    }

    // MARK: - Narrow Security Validator for Skill Markdown Files

    /// Surgical `.md`-only validator that allows reading `SKILL.md` / `commands/*.md` files
    /// (including symlinks to valid `.md` skill repositories) while strictly blocking credentials,
    /// dotfiles, non-Markdown files, and sensitive host directories (`~/.ssh`, `~/.aws`, Keychain, `/etc`, etc.).
    public static func isAllowedSkillMarkdownFile(
        url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let rawURL = url.standardizedFileURL
        let resolvedURL = rawURL.resolvingSymlinksInPath()

        for candidate in [rawURL, resolvedURL] {
            let name = candidate.lastPathComponent
            let ext = candidate.pathExtension.lowercased()
            // Strict Markdown-only, non-hidden filename check
            guard ext == "md", !name.isEmpty, !name.hasPrefix(".") else {
                return false
            }

            let path = candidate.path
            for sysPrefix in blockedSystemPathPrefixes {
                if path.hasPrefix(sysPrefix) || path == String(sysPrefix.dropLast()) {
                    return false
                }
            }

            let resolvedHome = homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            let rawHome = homeDirectory.standardizedFileURL.path
            for homeRoot in Set([resolvedHome, rawHome]) where !homeRoot.isEmpty {
                for rel in blockedResolvedHomeSubpaths {
                    let restricted = homeRoot + "/" + rel
                    if path == restricted || path.hasPrefix(restricted + "/") {
                        return false
                    }
                }
                // Inside ~/.claude or ~/.codex, ONLY allow explicit skills/ or commands/ subtrees
                for agentDir in [".claude", ".codex"] {
                    let rootAgent = homeRoot + "/" + agentDir
                    if path == rootAgent || path.hasPrefix(rootAgent + "/") {
                        let allowedSkills = rootAgent + "/skills/"
                        let allowedCommands = rootAgent + "/commands/"
                        if !path.hasPrefix(allowedSkills) && !path.hasPrefix(allowedCommands) {
                            return false
                        }
                    }
                }
            }
        }

        return true
    }

    // MARK: - Zero-Dependency YAML Frontmatter Parser

    public struct ParsedSkillMarkdown: Equatable, Sendable {
        public let frontmatter: [String: String]
        public let body: String
    }

    public static func parseFrontmatterAndBody(markdown: String) -> ParsedSkillMarkdown {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ParsedSkillMarkdown(frontmatter: [:], body: normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var closingIndex: Int? = nil
        for i in 1..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                closingIndex = i
                break
            }
        }

        guard let endIdx = closingIndex else {
            return ParsedSkillMarkdown(frontmatter: [:], body: normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var meta: [String: String] = [:]
        var i = 1
        while i < endIdx {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }

            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                let rawVal = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

                if rawVal == ">" || rawVal == ">-" || rawVal == "|" || rawVal == "|-" {
                    let isFolded = rawVal.hasPrefix(">")
                    var blockLines: [String] = []
                    i += 1
                    while i < endIdx {
                        let nextLine = lines[i]
                        if nextLine.hasPrefix(" ") || nextLine.hasPrefix("\t") {
                            blockLines.append(nextLine.trimmingCharacters(in: .whitespaces))
                            i += 1
                        } else if nextLine.trimmingCharacters(in: .whitespaces).isEmpty {
                            blockLines.append("")
                            i += 1
                        } else {
                            break
                        }
                    }
                    let joined = isFolded
                        ? blockLines.filter { !$0.isEmpty }.joined(separator: " ")
                        : blockLines.joined(separator: "\n")
                    meta[key] = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                } else {
                    meta[key] = unquoteYAMLValue(rawVal)
                }
            }
            i += 1
        }

        let bodySlice = (endIdx + 1 < lines.count) ? lines[(endIdx + 1)...].joined(separator: "\n") : ""
        return ParsedSkillMarkdown(
            frontmatter: meta,
            body: bodySlice.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func unquoteYAMLValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2 {
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
        }
        return value
    }

    // MARK: - Slash Autocomplete Query & Invocation Parsing

    /// Detects an active leading `/query` token while typing in the composer (single token, no spaces/newlines).
    public static func activeSlashQuery(in composerText: String) -> AISlashQueryMatch? {
        guard composerText.hasPrefix("/") else { return nil }
        guard !composerText.contains("\n") && !composerText.contains(" ") && !composerText.contains("\t") else {
            return nil
        }
        let query = String(composerText.dropFirst()).lowercased()
        let isMeta = (query == "skills" || query == "commands")
        return AISlashQueryMatch(query: query, isExactMetaBrowse: isMeta)
    }

    public static func filterSkills(_ skills: [AISkillDescriptor], query: String) -> [AISkillDescriptor] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return skills }
        if q == "skills" || q == "commands" {
            return skills.filter { !$0.isMetaBrowseCommand }
        }
        let scored: [(skill: AISkillDescriptor, score: Int)] = skills.compactMap { skill in
            let slug = skill.slug.lowercased()
            let title = skill.title.lowercased()
            let desc = skill.description.lowercased()
            if slug == q { return (skill, 0) }
            if slug.hasPrefix(q) { return (skill, 1) }
            if slug.contains(q) { return (skill, 2) }
            if title.contains(q) { return (skill, 3) }
            if desc.contains(q) { return (skill, 4) }
            return nil
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.skill.source.sortRank != rhs.skill.source.sortRank {
                return lhs.skill.source.sortRank < rhs.skill.source.sortRank
            }
            return lhs.skill.slug.localizedCaseInsensitiveCompare(rhs.skill.slug) == .orderedAscending
        }.map(\.skill)
    }

    /// Parses a submitted prompt for a leading `/slug [arguments]` command.
    public static func parseSlashCommand(
        in prompt: String,
        available: [AISkillDescriptor]
    ) -> AISlashParseResult? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let afterSlash = trimmed.dropFirst()
        let tokenEnd = afterSlash.firstIndex(where: { $0.isWhitespace }) ?? afterSlash.endIndex
        let slugToken = String(afterSlash[..<tokenEnd]).lowercased()
        guard !slugToken.isEmpty else { return nil }

        let rest = tokenEnd < afterSlash.endIndex
            ? String(afterSlash[tokenEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        if slugToken == "skills" || slugToken == "commands" {
            if let meta = available.first(where: { $0.isMetaBrowseCommand }) {
                return AISlashParseResult(descriptor: meta, arguments: rest, isMetaBrowse: true)
            }
            return nil
        }

        if let exact = available.first(where: { $0.slug.lowercased() == slugToken }) {
            return AISlashParseResult(descriptor: exact, arguments: rest, isMetaBrowse: exact.isMetaBrowseCommand)
        }
        return nil
    }

    // MARK: - Skill Loading, Interpolation & Security Sanitization

    public static func loadAndResolveSkill(
        _ descriptor: AISkillDescriptor,
        arguments: String,
        context: AIContextInput,
        workspaceRoot: URL?,
        redactSecrets: Bool,
        explicitSecrets: [String] = [],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> AISkillInvocation {
        var rawBody: String
        var skillDirURL: URL? = nil

        if let builtInBody = descriptor.builtInBody {
            rawBody = builtInBody
        } else if let filePath = descriptor.filePath {
            let fileURL = URL(fileURLWithPath: filePath)
            guard isAllowedSkillMarkdownFile(url: fileURL, homeDirectory: homeDirectory) else {
                throw AISkillRegistryError.blockedSkillPath(descriptor.slug)
            }
            guard let data = try? Data(contentsOf: fileURL),
                  !data.prefix(2048).contains(0),
                  let text = String(data: data, encoding: .utf8) else {
                throw AISkillRegistryError.unreadableSkillFile(fileURL.lastPathComponent)
            }
            let parsed = parseFrontmatterAndBody(markdown: text)
            rawBody = parsed.body
            skillDirURL = fileURL.deletingLastPathComponent()
        } else {
            throw AISkillRegistryError.unreadableSkillFile(descriptor.slug)
        }

        // Security: neutralize any third-party `!`shell command`` syntax so skills remain pure Markdown
        rawBody = sanitizeEmbeddedShellDirectives(rawBody)

        // Template variable interpolation ($ARGUMENTS, $1..$9, ${HELPER}, ${ACTIVE_FILE}, ${WORKSPACE_ROOT}, ${SKILL_DIR})
        let interpolated = interpolateTemplate(
            rawBody,
            arguments: arguments,
            context: context,
            workspaceRoot: workspaceRoot,
            skillDirURL: skillDirURL
        )

        var combinedBody = interpolated
        if combinedBody.count > maxSkillBodyChars {
            combinedBody = String(combinedBody.prefix(maxSkillBodyChars)) + "\n\n[Skill instructions truncated at \(maxSkillBodyChars) chars for model context budget]"
        }

        // Level 3 Progressive Disclosure: resolve local Markdown references (references/*.md or examples/*.md) inside the same skill folder
        var referencedFiles: [String] = []
        if let skillDir = skillDirURL {
            let refs = loadLocalMarkdownReferences(
                referencedIn: combinedBody,
                skillDir: skillDir,
                homeDirectory: homeDirectory
            )
            if !refs.isEmpty {
                var refBudget = maxReferenceExcerptChars
                var refBlocks: [String] = []
                for ref in refs where refBudget > 256 {
                    let snippet = String(ref.content.prefix(refBudget))
                    refBlocks.append("### Skill Reference: \(ref.relativePath)\n\(snippet)")
                    referencedFiles.append(ref.relativePath)
                    refBudget -= snippet.count
                }
                if !refBlocks.isEmpty {
                    combinedBody += "\n\n" + refBlocks.joined(separator: "\n\n")
                }
            }
        }

        if redactSecrets {
            let redacted = AISecretRedactor.redact(combinedBody, explicitSecrets: explicitSecrets)
            return AISkillInvocation(
                descriptor: descriptor,
                arguments: arguments,
                resolvedInstructionBody: redacted.text,
                wasRedacted: redacted.wasRedacted,
                referencedFiles: referencedFiles
            )
        }

        return AISkillInvocation(
            descriptor: descriptor,
            arguments: arguments,
            resolvedInstructionBody: combinedBody,
            wasRedacted: false,
            referencedFiles: referencedFiles
        )
    }

    /// Neutralizes `!`cmd`` backtick shell directives found in some third-party command files.
    public static func sanitizeEmbeddedShellDirectives(_ text: String) -> String {
        guard text.contains("!`") else { return text }
        guard let regex = try? NSRegularExpression(pattern: "!`([^`\\n]+)`", options: []) else {
            return text.replacingOccurrences(of: "!`", with: "`")
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "[shell execution disabled: `$1`]"
        )
    }

    private static func interpolateTemplate(
        _ template: String,
        arguments: String,
        context: AIContextInput,
        workspaceRoot: URL?,
        skillDirURL: URL?
    ) -> String {
        let trimmedArgs = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveArgs = trimmedArgs.isEmpty ? "(none specified — apply to active editor context)" : trimmedArgs
        var out = template
            .replacingOccurrences(of: "$ARGUMENTS", with: effectiveArgs)
            .replacingOccurrences(of: "${ARGUMENTS}", with: effectiveArgs)
            .replacingOccurrences(of: "${HELPER}", with: context.helperDisplayName ?? "Playwright")
            .replacingOccurrences(of: "${ACTIVE_FILE}", with: context.activeFileRelativePath ?? context.activeFilePath ?? "(none)")
            .replacingOccurrences(of: "${WORKSPACE_ROOT}", with: workspaceRoot?.path ?? "(no workspace)")

        if let skillDirURL {
            out = out
                .replacingOccurrences(of: "${SKILL_DIR}", with: skillDirURL.path)
                .replacingOccurrences(of: "${CLAUDE_SKILL_DIR}", with: skillDirURL.path)
        }

        // Positional arguments $1..$9 (and $0)
        let tokens = trimmedArgs.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for idx in (1...9).reversed() {
            let placeholder = "$\(idx)"
            if out.contains(placeholder) {
                let replacement = (idx - 1 < tokens.count) ? tokens[idx - 1] : ""
                out = out.replacingOccurrences(of: placeholder, with: replacement)
            }
        }
        if out.contains("$0") {
            out = out.replacingOccurrences(of: "$0", with: tokens.first ?? "")
        }

        return out
    }

    private static func loadLocalMarkdownReferences(
        referencedIn body: String,
        skillDir: URL,
        homeDirectory: URL
    ) -> [(relativePath: String, content: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: "(references|examples)/[A-Za-z0-9._/-]+\\.md",
            options: []
        ) else {
            return []
        }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = regex.matches(in: body, options: [], range: range)
        guard !matches.isEmpty else { return [] }

        let resolvedSkillDir = skillDir.standardizedFileURL.resolvingSymlinksInPath().path
        var seen = Set<String>()
        var results: [(String, String)] = []

        for match in matches {
            guard let swiftRange = Range(match.range, in: body) else { continue }
            let relPath = String(body[swiftRange])
            guard !relPath.contains(".."), seen.insert(relPath).inserted else { continue }

            let candidateURL = skillDir.appendingPathComponent(relPath).standardizedFileURL
            let resolvedCandidate = candidateURL.resolvingSymlinksInPath()
            // Must stay strictly inside the skill's own directory tree
            guard resolvedCandidate.path.hasPrefix(resolvedSkillDir + "/"),
                  isAllowedSkillMarkdownFile(url: candidateURL, homeDirectory: homeDirectory),
                  let data = try? Data(contentsOf: candidateURL),
                  data.count <= maxSkillFileBytes,
                  !data.prefix(2048).contains(0),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            results.append((relPath, sanitizeEmbeddedShellDirectives(text)))
            if results.count >= 2 { break }
        }
        return results
    }

    // MARK: - 1-Click Portable Skill Scaffolding

    public static func createSkillTemplate(
        rawSlug: String,
        description: String,
        inSkillsRootDirectory rootDir: URL
    ) throws -> URL {
        let slug = sanitizeSlug(rawSlug)
        guard !slug.isEmpty else {
            throw AISkillRegistryError.invalidSlug(rawSlug)
        }

        let fm = FileManager.default
        let skillFolder = rootDir.appendingPathComponent(slug, isDirectory: true)
        try fm.createDirectory(at: skillFolder, withIntermediateDirectories: true)

        let skillFile = skillFolder.appendingPathComponent("SKILL.md", isDirectory: false)
        if fm.fileExists(atPath: skillFile.path) {
            return skillFile
        }

        let cleanDesc = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Custom CodeceptJS automation skill for \(makeDisplayTitle(fromSlug: slug))."
            : description.trimmingCharacters(in: .whitespacesAndNewlines)

        let template = """
        ---
        name: \(slug)
        description: \(cleanDesc)
        argument-hint: "[optional goal or target file]"
        ---

        # \(makeDisplayTitle(fromSlug: slug))

        ## Objective
        \(cleanDesc)

        ## Instructions
        1. Inspect the active CodeceptJS file (`${ACTIVE_FILE}`) and configured helper (`${HELPER}`).
        2. Follow our team's selector, PageObject, and assertion conventions.
        3. Output clean, runnable CodeceptJS 4.x code in a fenced code block ready to Preview & Apply.

        ## User Request
        $ARGUMENTS
        """

        try template.write(to: skillFile, atomically: true, encoding: .utf8)
        return skillFile
    }

    // MARK: - Helpers

    public static func sanitizeSlug(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if (ch == "-" || ch == "_" || ch == " ") && !out.isEmpty && !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") {
            out.removeLast()
        }
        return String(out.prefix(48))
    }

    private static func makeDisplayTitle(fromSlug slug: String) -> String {
        slug
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { part in
                let s = String(part)
                if s.count <= 2 { return s.uppercased() }
                return s.prefix(1).uppercased() + s.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func firstSummaryLine(from body: String) -> String? {
        for rawLine in body.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("```") || trimmed.hasPrefix("---") {
                continue
            }
            let cleaned = trimmed.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return nil
    }
}
