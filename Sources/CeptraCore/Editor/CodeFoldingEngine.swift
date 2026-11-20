import Foundation

public enum FoldRegionKind: String, Equatable, Hashable, Sendable {
    case block
    case array
    case parens
    case comment
    case imports
    case gherkin
    case indentation
    case xmlTag
}

public struct FoldableRegion: Identifiable, Equatable, Hashable, Sendable {
    public var id: Int { startLine }
    /// 1-based line number of the opening line (stays visible when folded).
    public let startLine: Int
    /// 1-based last line included in the folded block (hidden when folded).
    public let endLine: Int
    /// UTF-16 range hidden when collapsed (`lineContentEnd(startLine) ..< lineContentEnd(endLine)`).
    public let hiddenRange: NSRange
    public let kind: FoldRegionKind
    public let closingToken: String

    public init(
        startLine: Int,
        endLine: Int,
        hiddenRange: NSRange,
        kind: FoldRegionKind,
        closingToken: String = ""
    ) {
        self.startLine = startLine
        self.endLine = endLine
        self.hiddenRange = hiddenRange
        self.kind = kind
        self.closingToken = closingToken
    }

    public var hiddenLineCount: Int {
        max(0, endLine - startLine)
    }

    public var badgeLabel: String {
        let count = hiddenLineCount
        let suffix = count == 1 ? "1 line" : "\(count) lines"
        if closingToken.isEmpty {
            return "⋯ \(suffix)"
        }
        return "⋯ \(suffix) \(closingToken)"
    }
}

public struct LineIndexTable: Equatable, Sendable {
    /// UTF-16 starting offset of each 1-based line (`lineStarts[0]` = line 1 = offset 0).
    public let lineStarts: [Int]
    /// UTF-16 ending offset of visible content on each line (excluding trailing `\r` / `\n`).
    public let lineContentEnds: [Int]
    public let utf16Length: Int

    public var lineCount: Int { lineStarts.count }

    public init(text: String) {
        let ns = text as NSString
        let len = ns.length
        self.utf16Length = len

        if len == 0 {
            self.lineStarts = [0]
            self.lineContentEnds = [0]
            return
        }

        var starts: [Int] = []
        var contentEnds: [Int] = []
        starts.reserveCapacity(max(16, len / 32))
        contentEnds.reserveCapacity(max(16, len / 32))

        var idx = 0
        while idx < len {
            starts.append(idx)
            var scan = idx
            while scan < len {
                let ch = ns.character(at: scan)
                if ch == 10 || ch == 13 { // \n or \r
                    break
                }
                scan += 1
            }
            contentEnds.append(scan)
            if scan < len {
                if ns.character(at: scan) == 13 && scan + 1 < len && ns.character(at: scan + 1) == 10 {
                    idx = scan + 2
                } else {
                    idx = scan + 1
                }
                if idx == len {
                    // Trailing newline creates an empty final line
                    starts.append(len)
                    contentEnds.append(len)
                }
            } else {
                idx = len
            }
        }

        self.lineStarts = starts
        self.lineContentEnds = contentEnds
    }

    /// O(log N) lookup returning the 1-based line number containing `utf16Offset`.
    public func lineNumber(forUTF16Offset offset: Int) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        let clamped = max(0, min(offset, utf16Length))
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= clamped {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }

    public func lineStartOffset(forOneBasedLine line: Int) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        let idx = max(0, min(line - 1, lineStarts.count - 1))
        return lineStarts[idx]
    }

    public func lineContentEndOffset(forOneBasedLine line: Int) -> Int {
        guard !lineContentEnds.isEmpty else { return 0 }
        let idx = max(0, min(line - 1, lineContentEnds.count - 1))
        return lineContentEnds[idx]
    }

    /// Full UTF-16 range of a 1-based line including its line terminator (if any).
    public func fullLineRange(forOneBasedLine line: Int) -> NSRange {
        guard !lineStarts.isEmpty else { return NSRange(location: 0, length: 0) }
        let idx = max(0, min(line - 1, lineStarts.count - 1))
        let start = lineStarts[idx]
        let end = (idx + 1 < lineStarts.count) ? lineStarts[idx + 1] : utf16Length
        return NSRange(location: start, length: max(0, end - start))
    }
}

public enum CodeFoldingEngine {
    /// Detects all foldable regions in `text` for `language`, sorted by `startLine` ascending
    /// with at most one canonical region per `startLine`.
    public static func detectRegions(
        in text: String,
        language: String,
        lineIndex: LineIndexTable? = nil
    ) -> [FoldableRegion] {
        let index = lineIndex ?? LineIndexTable(text: text)
        guard index.lineCount >= 2 else { return [] }

        let lang = language.lowercased()
        let raw: [FoldableRegion]
        switch lang {
        case "javascript", "typescript", "json":
            raw = detectCStyleRegions(in: text, includeImports: lang != "json", lineIndex: index)
        case "gherkin":
            raw = detectGherkinRegions(in: text, lineIndex: index)
        case "yaml":
            raw = detectIndentationRegions(in: text, commentPrefix: "#", lineIndex: index)
        case "markdown":
            raw = detectMarkdownRegions(in: text, lineIndex: index)
        case "xml":
            raw = detectXMLRegions(in: text, lineIndex: index)
        default:
            let braceRegions = detectCStyleRegions(in: text, includeImports: false, lineIndex: index)
            if !braceRegions.isEmpty {
                raw = braceRegions
            } else {
                raw = detectIndentationRegions(in: text, commentPrefix: "#", lineIndex: index)
            }
        }

        // Deduplicate by startLine: keep the widest span for each opening line
        var bestByStart: [Int: FoldableRegion] = [:]
        for region in raw {
            guard region.endLine > region.startLine, region.hiddenRange.length > 0 else { continue }
            if let existing = bestByStart[region.startLine] {
                if region.endLine > existing.endLine {
                    bestByStart[region.startLine] = region
                }
            } else {
                bestByStart[region.startLine] = region
            }
        }

        return bestByStart.values.sorted { $0.startLine < $1.startLine }
    }

    /// Merges hidden UTF-16 ranges of all currently collapsed regions into sorted, disjoint ranges
    /// ready for `NSLayoutManagerDelegate` glyph suppression.
    public static func mergedHiddenRanges(
        regions: [FoldableRegion],
        collapsedStartLines: Set<Int>
    ) -> [NSRange] {
        guard !collapsedStartLines.isEmpty else { return [] }
        let active = regions
            .filter { collapsedStartLines.contains($0.startLine) && $0.hiddenRange.length > 0 }
            .map(\.hiddenRange)
            .sorted { lhs, rhs in
                if lhs.location != rhs.location { return lhs.location < rhs.location }
                return lhs.length > rhs.length
            }

        var merged: [NSRange] = []
        for range in active {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                let newEnd = max(NSMaxRange(last), NSMaxRange(range))
                merged[merged.count - 1] = NSRange(location: last.location, length: newEnd - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Returns the innermost foldable region covering `oneBasedLine` (for Fold / Unfold at Caret).
    public static func innermostRegion(
        containingLine line: Int,
        in regions: [FoldableRegion]
    ) -> FoldableRegion? {
        regions
            .filter { $0.startLine <= line && line <= $0.endLine }
            .min { lhs, rhs in
                let lhsSpan = lhs.endLine - lhs.startLine
                let rhsSpan = rhs.endLine - rhs.startLine
                if lhsSpan != rhsSpan { return lhsSpan < rhsSpan }
                return lhs.startLine > rhs.startLine
            }
    }

    /// Returns all collapsed `startLine` keys whose hidden body conceals `oneBasedLine`.
    public static func collapsedStartLinesHiding(
        line: Int,
        regions: [FoldableRegion],
        collapsedStartLines: Set<Int>
    ) -> Set<Int> {
        var result = Set<Int>()
        for region in regions where collapsedStartLines.contains(region.startLine) {
            if region.startLine < line && line <= region.endLine {
                result.insert(region.startLine)
            }
        }
        return result
    }

    /// Returns collapsed `startLine` keys whose hidden range intersects or touches `characterRange`.
    public static func collapsedStartLinesIntersecting(
        characterRange: NSRange,
        regions: [FoldableRegion],
        collapsedStartLines: Set<Int>
    ) -> Set<Int> {
        var result = Set<Int>()
        let editStart = characterRange.location
        let editEnd = NSMaxRange(characterRange)
        for region in regions where collapsedStartLines.contains(region.startLine) {
            let hideStart = region.hiddenRange.location
            let hideEnd = NSMaxRange(region.hiddenRange)
            if characterRange.length == 0 {
                // Insertion strictly inside hidden range
                if editStart > hideStart && editStart < hideEnd {
                    result.insert(region.startLine)
                }
            } else {
                // Replacement/deletion overlapping hidden range
                if editStart < hideEnd && editEnd > hideStart {
                    result.insert(region.startLine)
                }
            }
        }
        return result
    }

    /// Maps collapsed line numbers safely after text edits (pruning any lines that no longer start a region).
    public static func validCollapsedStartLines(
        from previous: Set<Int>,
        regions: [FoldableRegion]
    ) -> Set<Int> {
        let validStarts = Set(regions.map(\.startLine))
        return previous.intersection(validStarts)
    }

    // MARK: - Helper to Build Region

    private static func makeRegion(
        startLine: Int,
        endLine: Int,
        kind: FoldRegionKind,
        closingToken: String = "",
        lineIndex: LineIndexTable
    ) -> FoldableRegion? {
        guard startLine >= 1, endLine > startLine, endLine <= lineIndex.lineCount else { return nil }
        let hideStart = lineIndex.lineContentEndOffset(forOneBasedLine: startLine)
        let hideEnd = lineIndex.lineContentEndOffset(forOneBasedLine: endLine)
        guard hideEnd > hideStart else { return nil }
        return FoldableRegion(
            startLine: startLine,
            endLine: endLine,
            hiddenRange: NSRange(location: hideStart, length: hideEnd - hideStart),
            kind: kind,
            closingToken: closingToken
        )
    }

    // MARK: - JS / TS / JSON Brace, Bracket, Paren, Block-Comment & Import Folding

    private static func detectCStyleRegions(
        in text: String,
        includeImports: Bool,
        lineIndex: LineIndexTable
    ) -> [FoldableRegion] {
        let ns = text as NSString
        let len = ns.length
        var regions: [FoldableRegion] = []

        struct OpenDelimiter {
            let char: unichar
            let line: Int
        }

        var stack: [OpenDelimiter] = []
        var i = 0
        var currentLine = 1

        var inString: unichar = 0 // ', ", `
        var escaped = false
        var inLineComment = false
        var blockCommentStartLine: Int? = nil

        while i < len {
            let c = ns.character(at: i)

            if c == 10 { // \n
                inLineComment = false
                currentLine += 1
                i += 1
                continue
            }

            if inLineComment {
                i += 1
                continue
            }

            if let commentStart = blockCommentStartLine {
                if c == 42 && i + 1 < len && ns.character(at: i + 1) == 47 { // */
                    if currentLine > commentStart,
                       let region = makeRegion(startLine: commentStart, endLine: currentLine, kind: .comment, closingToken: "*/", lineIndex: lineIndex) {
                        regions.append(region)
                    }
                    blockCommentStartLine = nil
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            if inString != 0 {
                if escaped {
                    escaped = false
                } else if c == 92 { // \
                    escaped = true
                } else if c == inString {
                    inString = 0
                }
                i += 1
                continue
            }

            // Start of comments
            if c == 47 && i + 1 < len { // /
                let next = ns.character(at: i + 1)
                if next == 47 { // //
                    inLineComment = true
                    i += 2
                    continue
                }
                if next == 42 { // /*
                    blockCommentStartLine = currentLine
                    i += 2
                    continue
                }
            }

            // Start of string literals (', ", `)
            if c == 39 || c == 34 || c == 96 {
                inString = c
                escaped = false
                i += 1
                continue
            }

            // Opening delimiters: { (123), [ (91), ( (40)
            if c == 123 || c == 91 || c == 40 {
                stack.append(OpenDelimiter(char: c, line: currentLine))
            } else if c == 125 || c == 93 || c == 41 { // }, ], )
                let expectedOpen: unichar = (c == 125) ? 123 : ((c == 93) ? 91 : 40)
                if let matchIdx = stack.lastIndex(where: { $0.char == expectedOpen }) {
                    let opener = stack[matchIdx]
                    stack.removeSubrange(matchIdx..<stack.count)
                    if currentLine > opener.line {
                        let kind: FoldRegionKind
                        let closing: String
                        switch expectedOpen {
                        case 123:
                            kind = .block
                            closing = "}"
                        case 91:
                            kind = .array
                            closing = "]"
                        default:
                            kind = .parens
                            closing = ")"
                        }
                        if let region = makeRegion(
                            startLine: opener.line,
                            endLine: currentLine,
                            kind: kind,
                            closingToken: closing,
                            lineIndex: lineIndex
                        ) {
                            regions.append(region)
                        }
                    }
                }
            }

            i += 1
        }

        // Consecutive multi-line import block folding (3+ consecutive import statements)
        if includeImports {
            let lines = extractLines(from: ns, lineIndex: lineIndex)
            var idx = 0
            while idx < lines.count {
                let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("import ") {
                    let blockStart = idx
                    var blockEnd = idx
                    var j = idx + 1
                    while j < lines.count {
                        let t = lines[j].trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix("import ") {
                            blockEnd = j
                            j += 1
                        } else if t.isEmpty {
                            // Allow a single blank line only if another import immediately follows
                            if j + 1 < lines.count && lines[j + 1].trimmingCharacters(in: .whitespaces).hasPrefix("import ") {
                                j += 1
                            } else {
                                break
                            }
                        } else {
                            break
                        }
                    }
                    if blockEnd - blockStart >= 2,
                       let region = makeRegion(
                        startLine: blockStart + 1,
                        endLine: blockEnd + 1,
                        kind: .imports,
                        closingToken: "",
                        lineIndex: lineIndex
                       ) {
                        regions.append(region)
                    }
                    idx = max(j, blockEnd + 1)
                } else {
                    idx += 1
                }
            }
        }

        return regions
    }

    // MARK: - Gherkin (.feature) Folding

    private static func detectGherkinRegions(in text: String, lineIndex: LineIndexTable) -> [FoldableRegion] {
        let ns = text as NSString
        let lines = extractLines(from: ns, lineIndex: lineIndex)

        struct SectionHeader {
            let line: Int     // 1-based
            let level: Int    // 0 = Feature, 1 = Rule, 2 = Background/Scenario/Scenario Outline, 3 = Examples
        }

        func sectionLevel(for trimmed: String) -> Int? {
            if trimmed.hasPrefix("Feature:") { return 0 }
            if trimmed.hasPrefix("Rule:") { return 1 }
            if trimmed.hasPrefix("Background:")
                || trimmed.hasPrefix("Scenario:")
                || trimmed.hasPrefix("Scenario Outline:")
                || trimmed.hasPrefix("Scenario Template:") {
                return 2
            }
            if trimmed.hasPrefix("Examples:") { return 3 }
            return nil
        }

        var openSections: [SectionHeader] = []
        var regions: [FoldableRegion] = []

        func lastNonBlankLine(beforeOneBasedLine limitLine: Int, minLine: Int) -> Int {
            var candidate = limitLine - 1
            while candidate > minLine {
                let t = lines[candidate - 1].trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && !t.hasPrefix("@") {
                    break
                }
                candidate -= 1
            }
            return candidate
        }

        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let oneBased = i + 1
            if let level = sectionLevel(for: trimmed) {
                while let top = openSections.last, top.level >= level {
                    openSections.removeLast()
                    let endLine = lastNonBlankLine(beforeOneBasedLine: oneBased, minLine: top.line)
                    if let region = makeRegion(startLine: top.line, endLine: endLine, kind: .gherkin, lineIndex: lineIndex) {
                        regions.append(region)
                    }
                }
                openSections.append(SectionHeader(line: oneBased, level: level))
            }
        }

        let finalNonBlank = lastNonBlankLine(beforeOneBasedLine: lines.count + 1, minLine: 1)
        while let top = openSections.popLast() {
            if let region = makeRegion(startLine: top.line, endLine: finalNonBlank, kind: .gherkin, lineIndex: lineIndex) {
                regions.append(region)
            }
        }

        return regions
    }

    // MARK: - YAML / Indentation-Based Folding

    private static func detectIndentationRegions(
        in text: String,
        commentPrefix: String,
        lineIndex: LineIndexTable
    ) -> [FoldableRegion] {
        let ns = text as NSString
        let lines = extractLines(from: ns, lineIndex: lineIndex)

        struct LineMeta {
            let lineNumber: Int
            let indent: Int
            let isBlankOrComment: Bool
        }

        let metas: [LineMeta] = lines.enumerated().map { idx, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let isIgnored = trimmed.isEmpty || (!commentPrefix.isEmpty && trimmed.hasPrefix(commentPrefix))
            var indent = 0
            for ch in raw {
                if ch == " " { indent += 1 }
                else if ch == "\t" { indent += 2 }
                else { break }
            }
            return LineMeta(lineNumber: idx + 1, indent: indent, isBlankOrComment: isIgnored)
        }

        var regions: [FoldableRegion] = []
        for i in 0..<metas.count {
            guard !metas[i].isBlankOrComment else { continue }
            let baseIndent = metas[i].indent
            var lastChildLine = metas[i].lineNumber
            var j = i + 1
            while j < metas.count {
                if metas[j].isBlankOrComment {
                    j += 1
                    continue
                }
                if metas[j].indent > baseIndent {
                    lastChildLine = metas[j].lineNumber
                    j += 1
                } else {
                    break
                }
            }
            if lastChildLine > metas[i].lineNumber,
               let region = makeRegion(startLine: metas[i].lineNumber, endLine: lastChildLine, kind: .indentation, lineIndex: lineIndex) {
                regions.append(region)
            }
        }

        return regions
    }

    // MARK: - Markdown Heading & Code Fence Folding

    private static func detectMarkdownRegions(in text: String, lineIndex: LineIndexTable) -> [FoldableRegion] {
        let ns = text as NSString
        let lines = extractLines(from: ns, lineIndex: lineIndex)
        var regions: [FoldableRegion] = []

        var fenceStart: Int? = nil
        var headings: [(line: Int, level: Int)] = []

        func lastNonBlank(before lineLimit: Int, minLine: Int) -> Int {
            var c = lineLimit - 1
            while c > minLine && lines[c - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                c -= 1
            }
            return c
        }

        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let oneBased = i + 1

            if trimmed.hasPrefix("```") {
                if let start = fenceStart {
                    if let region = makeRegion(startLine: start, endLine: oneBased, kind: .block, closingToken: "```", lineIndex: lineIndex) {
                        regions.append(region)
                    }
                    fenceStart = nil
                } else {
                    fenceStart = oneBased
                }
                continue
            }
            if fenceStart != nil { continue }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes >= 1 && hashes <= 6 && trimmed.dropFirst(hashes).first == " " {
                    while let top = headings.last, top.level >= hashes {
                        headings.removeLast()
                        let endLine = lastNonBlank(before: oneBased, minLine: top.line)
                        if let region = makeRegion(startLine: top.line, endLine: endLine, kind: .indentation, lineIndex: lineIndex) {
                            regions.append(region)
                        }
                    }
                    headings.append((line: oneBased, level: hashes))
                }
            }
        }

        let finalNonBlank = lastNonBlank(before: lines.count + 1, minLine: 1)
        while let top = headings.popLast() {
            if let region = makeRegion(startLine: top.line, endLine: finalNonBlank, kind: .indentation, lineIndex: lineIndex) {
                regions.append(region)
            }
        }
        return regions
    }

    // MARK: - XML / HTML Tag Folding

    private static func detectXMLRegions(in text: String, lineIndex: LineIndexTable) -> [FoldableRegion] {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"<(/?)([A-Za-z_][A-Za-z0-9_.:-]*)(?:\s[^>]*)?(/?)>"#) else {
            return []
        }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var stack: [(tag: String, line: Int)] = []
        var regions: [FoldableRegion] = []

        for match in matches {
            let isClosing = match.range(at: 1).length > 0
            let tag = ns.substring(with: match.range(at: 2))
            let isSelfClosing = match.range(at: 3).length > 0
            if isSelfClosing { continue }
            let line = lineIndex.lineNumber(forUTF16Offset: match.range.location)

            if !isClosing {
                stack.append((tag: tag, line: line))
            } else if let idx = stack.lastIndex(where: { $0.tag == tag }) {
                let opener = stack[idx]
                stack.removeSubrange(idx..<stack.count)
                if line > opener.line,
                   let region = makeRegion(startLine: opener.line, endLine: line, kind: .xmlTag, closingToken: "</\(tag)>", lineIndex: lineIndex) {
                    regions.append(region)
                }
            }
        }
        return regions
    }

    private static func extractLines(from ns: NSString, lineIndex: LineIndexTable) -> [String] {
        var result: [String] = []
        result.reserveCapacity(lineIndex.lineCount)
        for idx in 0..<lineIndex.lineCount {
            let start = lineIndex.lineStarts[idx]
            let end = lineIndex.lineContentEnds[idx]
            result.append(ns.substring(with: NSRange(location: start, length: max(0, end - start))))
        }
        return result
    }
}
