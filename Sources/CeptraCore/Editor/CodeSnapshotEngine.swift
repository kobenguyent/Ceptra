import Foundation

public enum CodeSnapshotScope: String, CaseIterable, Codable, Identifiable, Equatable, Hashable, Sendable {
    case selection
    case currentBlock
    case fullFile

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .selection: return "Selection"
        case .currentBlock: return "Code Block"
        case .fullFile: return "Full File"
        }
    }
}

public enum CodeSnapshotBackground: String, CaseIterable, Codable, Identifiable, Equatable, Hashable, Sendable {
    case candy
    case midnight
    case breeze
    case sunset
    case emerald
    case amber
    case monochrome
    case transparent

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .candy: return "Candy"
        case .midnight: return "Midnight"
        case .breeze: return "Breeze"
        case .sunset: return "Sunset"
        case .emerald: return "Emerald"
        case .amber: return "Amber"
        case .monochrome: return "Graphite"
        case .transparent: return "Transparent"
        }
    }
}

public enum CodeSnapshotTheme: String, CaseIterable, Codable, Identifiable, Equatable, Hashable, Sendable {
    case obsidian
    case dracula
    case catppuccin
    case tokyoNight
    case paperLight

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .obsidian: return "Obsidian"
        case .dracula: return "Dracula"
        case .catppuccin: return "Catppuccin"
        case .tokyoNight: return "Tokyo Night"
        case .paperLight: return "Paper Light"
        }
    }

    public var isDark: Bool {
        self != .paperLight
    }
}

public enum CodeSnapshotWindowChrome: String, CaseIterable, Codable, Identifiable, Equatable, Hashable, Sendable {
    case macOS
    case minimal
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .minimal: return "Minimal"
        case .none: return "None"
        }
    }
}

public enum CodeSnapshotPadding: String, CaseIterable, Codable, Identifiable, Equatable, Hashable, Sendable {
    case compact
    case cozy
    case spacious

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .cozy: return "Cozy"
        case .spacious: return "Spacious"
        }
    }

    public var horizontalPoints: Double {
        switch self {
        case .compact: return 32
        case .cozy: return 52
        case .spacious: return 76
        }
    }

    public var verticalPoints: Double {
        switch self {
        case .compact: return 28
        case .cozy: return 48
        case .spacious: return 72
        }
    }
}

public struct CodeSnapshotStyle: Codable, Equatable, Hashable, Sendable {
    public var background: CodeSnapshotBackground
    public var theme: CodeSnapshotTheme
    public var windowChrome: CodeSnapshotWindowChrome
    public var padding: CodeSnapshotPadding
    public var fontSize: Double
    public var scale: Int
    public var showLineNumbers: Bool
    public var showTitle: Bool
    public var showLanguageBadge: Bool
    public var showWatermark: Bool
    public var autoDedent: Bool

    public init(
        background: CodeSnapshotBackground = .candy,
        theme: CodeSnapshotTheme = .obsidian,
        windowChrome: CodeSnapshotWindowChrome = .macOS,
        padding: CodeSnapshotPadding = .cozy,
        fontSize: Double = 14.0,
        scale: Int = 2,
        showLineNumbers: Bool = true,
        showTitle: Bool = true,
        showLanguageBadge: Bool = true,
        showWatermark: Bool = false,
        autoDedent: Bool = true
    ) {
        self.background = background
        self.theme = theme
        self.windowChrome = windowChrome
        self.padding = padding
        self.fontSize = min(max(fontSize, 11.0), 22.0)
        self.scale = (scale == 3) ? 3 : 2
        self.showLineNumbers = showLineNumbers
        self.showTitle = showTitle
        self.showLanguageBadge = showLanguageBadge
        self.showWatermark = showWatermark
        self.autoDedent = autoDedent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.background = try c.decodeIfPresent(CodeSnapshotBackground.self, forKey: .background) ?? .candy
        self.theme = try c.decodeIfPresent(CodeSnapshotTheme.self, forKey: .theme) ?? .obsidian
        self.windowChrome = try c.decodeIfPresent(CodeSnapshotWindowChrome.self, forKey: .windowChrome) ?? .macOS
        self.padding = try c.decodeIfPresent(CodeSnapshotPadding.self, forKey: .padding) ?? .cozy
        let rawFont = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 14.0
        self.fontSize = min(max(rawFont, 11.0), 22.0)
        let rawScale = try c.decodeIfPresent(Int.self, forKey: .scale) ?? 2
        self.scale = (rawScale == 3) ? 3 : 2
        self.showLineNumbers = try c.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? true
        self.showTitle = try c.decodeIfPresent(Bool.self, forKey: .showTitle) ?? true
        self.showLanguageBadge = try c.decodeIfPresent(Bool.self, forKey: .showLanguageBadge) ?? true
        self.showWatermark = try c.decodeIfPresent(Bool.self, forKey: .showWatermark) ?? false
        self.autoDedent = try c.decodeIfPresent(Bool.self, forKey: .autoDedent) ?? true
    }
}

public struct CodeSnapshotExtraction: Equatable, Sendable {
    public let code: String
    public let rawCode: String
    public let startLineNumber: Int
    public let endLineNumber: Int
    public let scope: CodeSnapshotScope
    public let blockLabel: String?

    public var lineCount: Int {
        max(1, endLineNumber - startLineNumber + 1)
    }

    public init(
        code: String,
        rawCode: String,
        startLineNumber: Int,
        endLineNumber: Int,
        scope: CodeSnapshotScope,
        blockLabel: String? = nil
    ) {
        self.code = code
        self.rawCode = rawCode
        self.startLineNumber = startLineNumber
        self.endLineNumber = endLineNumber
        self.scope = scope
        self.blockLabel = blockLabel
    }
}

public enum CodeTokenKind: String, Equatable, Hashable, Sendable {
    case plain
    case keyword
    case dsl
    case actor
    case typeName
    case property
    case string
    case number
    case tag
    case comment
}

public struct CodeHighlightSpan: Equatable, Sendable {
    public let range: NSRange
    public let kind: CodeTokenKind
    public let isBold: Bool

    public init(range: NSRange, kind: CodeTokenKind, isBold: Bool = false) {
        self.range = range
        self.kind = kind
        self.isBold = isBold
    }
}

public enum CodeSnapshotEngine {
    /// Extracts the requested code block (explicit selection, enclosing block at caret, or full file),
    /// trimming leading/trailing empty lines and optionally dedenting common leading whitespace while
    /// keeping the exact 1-based starting line number from the original document.
    public static func extract(
        from fullText: String,
        language: String,
        selectedRange: NSRange,
        caretLine: Int,
        preferredScope: CodeSnapshotScope? = nil,
        autoDedent: Bool = true
    ) -> CodeSnapshotExtraction {
        let lineIndex = LineIndexTable(text: fullText)
        let totalLines = max(1, lineIndex.lineCount)
        let ns = fullText as NSString
        let hasSelection = selectedRange.length > 0 && selectedRange.location < ns.length

        let scope: CodeSnapshotScope
        if let preferredScope {
            if preferredScope == .selection && !hasSelection {
                scope = .currentBlock
            } else {
                scope = preferredScope
            }
        } else {
            scope = hasSelection ? .selection : .currentBlock
        }

        let startLine: Int
        let endLine: Int
        var label: String? = nil

        switch scope {
        case .selection:
            let safeStart = max(0, min(selectedRange.location, ns.length))
            let rawEnd = max(safeStart, min(NSMaxRange(selectedRange), ns.length))
            // If selection ends exactly at the start of a new line (trailing newline selected),
            // exclude that empty trailing line so we capture exactly the highlighted lines.
            let adjustedEnd: Int
            if rawEnd > safeStart && rawEnd > 0 {
                let prevChar = ns.character(at: rawEnd - 1)
                adjustedEnd = (prevChar == 10 || prevChar == 13) ? max(safeStart, rawEnd - 1) : rawEnd - 1
            } else {
                adjustedEnd = safeStart
            }
            startLine = lineIndex.lineNumber(forUTF16Offset: safeStart)
            endLine = max(startLine, lineIndex.lineNumber(forUTF16Offset: adjustedEnd))

        case .currentBlock:
            let clampedCaret = max(1, min(caretLine, totalLines))
            let blockBounds = detectSmartBlockLines(
                in: fullText,
                language: language,
                caretLine: clampedCaret,
                lineIndex: lineIndex
            )
            startLine = blockBounds.start
            endLine = blockBounds.end
            label = blockBounds.label

        case .fullFile:
            startLine = 1
            endLine = totalLines
        }

        return buildExtraction(
            from: ns,
            lineIndex: lineIndex,
            startLine: startLine,
            endLine: endLine,
            scope: scope,
            blockLabel: label,
            autoDedent: autoDedent
        )
    }

    /// Generates a clean suggested PNG filename (e.g. `login_test-L6-L11.png`).
    public static func suggestedFilename(
        fileName: String,
        extraction: CodeSnapshotExtraction
    ) -> String {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let sanitizedStem = stem.isEmpty ? "code-snippet" : stem
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = sanitizedStem.isEmpty ? "code-snippet" : sanitizedStem
        if extraction.scope == .fullFile {
            return "\(base).png"
        }
        if extraction.startLineNumber == extraction.endLineNumber {
            return "\(base)-L\(extraction.startLineNumber).png"
        }
        return "\(base)-L\(extraction.startLineNumber)-L\(extraction.endLineNumber).png"
    }

    /// Human-readable short badge label for the language (e.g. `TS`, `JS`, `GHERKIN`, `JSON`).
    public static func languageBadge(for language: String, fileName: String = "") -> String {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch ext {
        case "ts", "mts", "cts": return "TS"
        case "tsx": return "TSX"
        case "js", "mjs", "cjs": return "JS"
        case "jsx": return "JSX"
        case "feature": return "GHERKIN"
        case "json": return "JSON"
        case "yml", "yaml": return "YAML"
        case "md": return "MD"
        case "sh", "zsh", "bash": return "SHELL"
        case "xml", "html": return ext.uppercased()
        default: break
        }
        switch language.lowercased() {
        case "typescript": return "TS"
        case "javascript": return "JS"
        case "gherkin": return "GHERKIN"
        case "json": return "JSON"
        case "yaml": return "YAML"
        case "markdown": return "MD"
        case "shell": return "SHELL"
        case "xml": return "XML"
        default: return "CODE"
        }
    }

    // MARK: - Smart Block Detection

    private static func detectSmartBlockLines(
        in text: String,
        language: String,
        caretLine: Int,
        lineIndex: LineIndexTable
    ) -> (start: Int, end: Int, label: String?) {
        let totalLines = lineIndex.lineCount
        let ns = text as NSString
        let regions = CodeFoldingEngine.detectRegions(in: text, language: language, lineIndex: lineIndex)

        func lineText(_ oneBasedLine: Int) -> String {
            let start = lineIndex.lineStartOffset(forOneBasedLine: oneBasedLine)
            let end = lineIndex.lineContentEndOffset(forOneBasedLine: oneBasedLine)
            guard end >= start else { return "" }
            return ns.substring(with: NSRange(location: start, length: end - start))
        }

        let containing = regions
            .filter { $0.startLine <= caretLine && caretLine <= $0.endLine }
            .sorted { lhs, rhs in
                let lhsSpan = lhs.endLine - lhs.startLine
                let rhsSpan = rhs.endLine - rhs.startLine
                if lhsSpan != rhsSpan { return lhsSpan < rhsSpan }
                return lhs.startLine > rhs.startLine
            }

        if let innermost = containing.first {
            // If caret is inside a tiny inner object/array (e.g. `{ username: 'a' }`) inside a
            // CodeceptJS Scenario / Before / After / function block of reasonable length, prefer the enclosing Scenario/function block.
            var chosen = innermost
            let innerSpan = innermost.endLine - innermost.startLine + 1
            if innerSpan <= 6 {
                for outer in containing.dropFirst() {
                    let outerSpan = outer.endLine - outer.startLine + 1
                    guard outerSpan <= 55 else { continue }
                    let header = lineText(outer.startLine).trimmingCharacters(in: .whitespaces)
                    if isMeaningfulBlockHeader(header) {
                        chosen = outer
                        break
                    }
                }
            }
            // For Gherkin scenarios, include immediately preceding `@tag` lines above `Scenario:`
            var blockStart = chosen.startLine
            if language.lowercased() == "gherkin" {
                while blockStart > 1 {
                    let prev = lineText(blockStart - 1).trimmingCharacters(in: .whitespaces)
                    if prev.hasPrefix("@") {
                        blockStart -= 1
                    } else {
                        break
                    }
                }
            }
            let headerText = lineText(chosen.startLine).trimmingCharacters(in: .whitespaces)
            return (blockStart, chosen.endLine, extractBlockLabel(from: headerText))
        }

        // Fallback: if file is concise (<= 36 lines), capture full file cleanly
        if totalLines <= 36 {
            return (1, totalLines, nil)
        }

        // Otherwise capture the contiguous non-blank paragraph around caretLine
        var start = caretLine
        while start > 1 && !lineText(start - 1).trimmingCharacters(in: .whitespaces).isEmpty {
            start -= 1
        }
        var end = caretLine
        while end < totalLines && !lineText(end + 1).trimmingCharacters(in: .whitespaces).isEmpty {
            end += 1
        }
        return (start, end, nil)
    }

    private static func isMeaningfulBlockHeader(_ trimmedLine: String) -> Bool {
        let prefixes = [
            "Scenario(", "Scenario.", "xScenario(", "Feature(",
            "Before(", "After(", "BeforeSuite(", "AfterSuite(", "Data(",
            "Scenario:", "Scenario Outline:", "Background:",
            "async function ", "function ", "export function ", "export async function ",
            "export default ", "export const ", "class ", "export class "
        ]
        return prefixes.contains(where: { trimmedLine.hasPrefix($0) })
    }

    private static func extractBlockLabel(from trimmedLine: String) -> String? {
        if let match = trimmedLine.range(of: #"(?:Scenario|xScenario|Feature)\s*\(\s*['"`]([^'"`]+)['"`]"#, options: .regularExpression) {
            let sub = String(trimmedLine[match])
            if let qStart = sub.firstIndex(where: { $0 == "'" || $0 == "\"" || $0 == "`" }),
               let qEnd = sub.lastIndex(where: { $0 == "'" || $0 == "\"" || $0 == "`" }),
               qEnd > qStart {
                let inner = String(sub[sub.index(after: qStart)..<qEnd])
                return inner.isEmpty ? nil : inner
            }
        }
        if trimmedLine.hasPrefix("Scenario:") || trimmedLine.hasPrefix("Scenario Outline:") {
            let rest = trimmedLine.split(separator: ":", maxSplits: 1).dropFirst().first?.trimmingCharacters(in: .whitespaces)
            return (rest?.isEmpty == false) ? rest : nil
        }
        return nil
    }

    private static func buildExtraction(
        from ns: NSString,
        lineIndex: LineIndexTable,
        startLine: Int,
        endLine: Int,
        scope: CodeSnapshotScope,
        blockLabel: String?,
        autoDedent: Bool
    ) -> CodeSnapshotExtraction {
        let safeStart = max(1, min(startLine, lineIndex.lineCount))
        let safeEnd = max(safeStart, min(endLine, lineIndex.lineCount))

        var lines: [String] = []
        lines.reserveCapacity(safeEnd - safeStart + 1)
        for lineNo in safeStart...safeEnd {
            let s = lineIndex.lineStartOffset(forOneBasedLine: lineNo)
            let e = lineIndex.lineContentEndOffset(forOneBasedLine: lineNo)
            lines.append(e >= s ? ns.substring(with: NSRange(location: s, length: e - s)) : "")
        }

        // Trim leading and trailing blank lines while keeping accurate line numbering
        var trimmedStartLine = safeStart
        while lines.count > 1 && lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
            trimmedStartLine += 1
        }
        var trimmedEndLine = trimmedStartLine + lines.count - 1
        while lines.count > 1 && lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
            trimmedEndLine -= 1
        }

        // Expand tabs to 2 spaces for consistent alignment in rendered image
        let expanded = lines.map { $0.replacingOccurrences(of: "\t", with: "  ") }
        let rawCode = expanded.joined(separator: "\n")

        let finalCode: String
        if autoDedent {
            let minIndent = expanded
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { line in line.prefix(while: { $0 == " " }).count }
                .min() ?? 0
            if minIndent > 0 {
                finalCode = expanded.map { line in
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        return ""
                    }
                    return String(line.dropFirst(min(minIndent, line.count)))
                }.joined(separator: "\n")
            } else {
                finalCode = rawCode
            }
        } else {
            finalCode = rawCode
        }

        return CodeSnapshotExtraction(
            code: finalCode,
            rawCode: rawCode,
            startLineNumber: trimmedStartLine,
            endLineNumber: trimmedEndLine,
            scope: scope,
            blockLabel: blockLabel
        )
    }

    // MARK: - Syntax Tokenization (Precedence-Safe)

    /// Produces ordered syntax highlight spans for `code` in `language`.
    /// Later rules (such as strings and comments) override earlier rules so keywords inside
    /// strings or comments never mis-highlight.
    public static func tokenize(code: String, language: String) -> [CodeHighlightSpan] {
        let ns = code as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard fullRange.length > 0 else { return [] }

        var spans: [CodeHighlightSpan] = []

        func collect(
            _ pattern: String,
            kind: CodeTokenKind,
            isBold: Bool = false,
            options: NSRegularExpression.Options = []
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: code, range: fullRange) where match.range.length > 0 {
                spans.append(CodeHighlightSpan(range: match.range, kind: kind, isBold: isBold))
            }
        }

        switch language.lowercased() {
        case "gherkin":
            collect(#"^\s*(?:Feature|Rule|Background|Scenario Outline|Scenario Template|Scenario|Examples):"#, kind: .dsl, isBold: true, options: [.anchorsMatchLines])
            collect(#"^\s*(?:Given|When|Then|And|But)\b"#, kind: .actor, isBold: true, options: [.anchorsMatchLines])
            collect(#"@[A-Za-z0-9_:-]+"#, kind: .tag, isBold: true)
            collect(#"\b\d+(?:\.\d+)?\b"#, kind: .number)
            collect(#""(?:\\.|[^"\\])*""#, kind: .string)
            collect(#"^\s*#.*$"#, kind: .comment, options: [.anchorsMatchLines])

        case "json":
            collect(#""[^"]+"\s*(?=:)"#, kind: .property)
            collect(#":\s*"(?:\\.|[^"\\])*""#, kind: .string)
            collect(#"\b(?:true|false|null)\b"#, kind: .keyword)
            collect(#"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, kind: .number)

        case "yaml":
            collect(#"^\s*[A-Za-z0-9_.-]+\s*(?=:)"#, kind: .property, options: [.anchorsMatchLines])
            collect(#"\b(?:true|false|null|yes|no)\b"#, kind: .keyword)
            collect(#"\b\d+(?:\.\d+)?\b"#, kind: .number)
            collect(#"'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*""#, kind: .string)
            collect(#"#[^\n]*"#, kind: .comment)

        case "markdown":
            collect(#"^#{1,6}\s+.*$"#, kind: .dsl, isBold: true, options: [.anchorsMatchLines])
            collect(#"`[^`\n]+`"#, kind: .actor)
            collect(#"^\s*[-*+]\s+"#, kind: .keyword, options: [.anchorsMatchLines])

        case "shell":
            collect(#"\b(?:if|then|else|fi|for|in|do|done|case|esac|export|local|return|set|exit|echo|cd|npm|npx|bun|pnpm|yarn)\b"#, kind: .keyword)
            collect(#"\$[A-Za-z0-9_{}?@#*-]+"#, kind: .dsl)
            collect(#"'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*""#, kind: .string)
            collect(#"#[^\n]*"#, kind: .comment)

        case "xml", "html":
            collect(#"</?[A-Za-z0-9_:-]+|/?>"#, kind: .dsl)
            collect(#"\b[A-Za-z0-9_:-]+(?==)"#, kind: .property)
            collect(#""[^"]*""#, kind: .string)
            collect(#"<!--[\s\S]*?-->"#, kind: .comment)

        case "plaintext":
            collect(#"^[A-Z0-9_]+(?==)"#, kind: .property, options: [.anchorsMatchLines])
            collect(#"^\s*#.*$"#, kind: .comment, options: [.anchorsMatchLines])

        default:
            // TypeScript / JavaScript / CodeceptJS 4.x
            collect(#"\b(?:import|export|from|const|let|var|async|await|return|if|else|for|while|switch|case|break|continue|try|catch|finally|throw|new|class|extends|implements|default|function|type|interface|enum|as|typeof|keyof|readonly|public|private|protected|static|true|false|null|undefined|void)\b"#, kind: .keyword)
            collect(#"\b(?:CodeceptJS|Promise|Array|Record|Partial|Pick|Omit|Map|Set|URL|Error|Buffer|string|number|boolean|unknown|any|never)\b"#, kind: .typeName)
            collect(#"\b[A-Za-z_$][\w$]*(?=\s*:(?!:))"#, kind: .property)
            collect(#"\b(?:Feature|Scenario|xScenario|BeforeSuite|AfterSuite|Before|After|Data|DataTable|within|session|tryTo|retryTo|locate|secret|inject|pause|eachElement|actor|Helper)\b"#, kind: .dsl, isBold: true)
            collect(#"\bI(?:\.retry\([^)]*\))?\.[A-Za-z_$][\w$]*"#, kind: .actor)
            collect(#"\b\d+(?:_\d+)*(?:\.\d+)?\b"#, kind: .number)
            // Strings & comments applied last so they win over keywords/properties inside literals
            collect(#"'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*"|`(?:\\.|[^`\\])*`"#, kind: .string)
            collect(#"@[A-Za-z0-9_:-]+"#, kind: .tag, isBold: true)
            collect(#"//[^\n]*"#, kind: .comment)
            collect(#"/\*[\s\S]*?\*/"#, kind: .comment)
        }

        return spans
    }
}
