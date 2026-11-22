import Foundation

public struct AIExtractedCodeBlock: Equatable, Identifiable, Sendable {
    public let id: String
    public let language: String
    public let code: String

    public init(id: String, language: String, code: String) {
        self.id = id
        self.language = language
        self.code = code
    }
}

public enum AIMarkdownSegment: Equatable, Identifiable, Sendable {
    case prose(id: String, text: String)
    case code(AIExtractedCodeBlock)

    public var id: String {
        switch self {
        case .prose(let id, _): return id
        case .code(let block): return block.id
        }
    }
}

public enum AIDiffLineKind: String, Equatable, Sendable {
    case unchanged
    case removed
    case added
}

public struct AIDiffLine: Equatable, Identifiable, Sendable {
    public let id: Int
    public let kind: AIDiffLineKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String

    public init(id: Int, kind: AIDiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String) {
        self.id = id
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

public struct AIDiffResult: Equatable, Sendable {
    public let lines: [AIDiffLine]
    public let addedCount: Int
    public let removedCount: Int

    public var hasChanges: Bool { addedCount > 0 || removedCount > 0 }
}

/// Parses fenced Markdown code blocks and computes clean line-by-line diffs for safe AI apply.
public enum AICodeDiffEngine {
    /// Splits Markdown into interleaved prose and fenced code block segments.
    /// Handles streaming (unclosed final fence) cleanly without losing text.
    public static func parseMarkdownSegments(_ markdown: String) -> [AIMarkdownSegment] {
        let lines = markdown.components(separatedBy: "\n")
        var segments: [AIMarkdownSegment] = []
        var proseBuffer: [String] = []
        var codeBuffer: [String] = []
        var inFence = false
        var fenceLanguage = ""
        var segmentIndex = 0

        func flushProse() {
            let joined = proseBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                segments.append(.prose(id: "prose-\(segmentIndex)", text: joined))
                segmentIndex += 1
            }
            proseBuffer.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            let code = codeBuffer.joined(separator: "\n")
            segments.append(.code(AIExtractedCodeBlock(
                id: "code-\(segmentIndex)",
                language: fenceLanguage,
                code: code
            )))
            segmentIndex += 1
            codeBuffer.removeAll(keepingCapacity: true)
            fenceLanguage = ""
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !inFence {
                    flushProse()
                    inFence = true
                    fenceLanguage = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .first ?? ""
                } else {
                    flushCode()
                    inFence = false
                }
            } else if inFence {
                codeBuffer.append(line)
            } else {
                proseBuffer.append(line)
            }
        }

        if inFence {
            flushCode()
        } else {
            flushProse()
        }

        return segments
    }

    public static func extractCodeBlocks(from markdown: String) -> [AIExtractedCodeBlock] {
        parseMarkdownSegments(markdown).compactMap { segment in
            if case .code(let block) = segment { return block }
            return nil
        }
    }

    /// Computes a line-level unified diff using LCS with prefix/suffix trimming.
    public static func computeDiff(original: String, proposed: String) -> AIDiffResult {
        let oldLines = original.isEmpty ? [] : original.components(separatedBy: "\n")
        let newLines = proposed.isEmpty ? [] : proposed.components(separatedBy: "\n")

        // Trim common prefix & suffix so large files diff in milliseconds
        var prefixLen = 0
        while prefixLen < oldLines.count && prefixLen < newLines.count && oldLines[prefixLen] == newLines[prefixLen] {
            prefixLen += 1
        }

        var oldEnd = oldLines.count
        var newEnd = newLines.count
        while oldEnd > prefixLen && newEnd > prefixLen && oldLines[oldEnd - 1] == newLines[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }

        let midOld = Array(oldLines[prefixLen..<oldEnd])
        let midNew = Array(newLines[prefixLen..<newEnd])

        var result: [AIDiffLine] = []
        var nextID = 0
        var added = 0
        var removed = 0

        // Prefix
        for i in 0..<prefixLen {
            result.append(AIDiffLine(id: nextID, kind: .unchanged, oldLineNumber: i + 1, newLineNumber: i + 1, text: oldLines[i]))
            nextID += 1
        }

        // Guard O(N*M) DP memory for extreme middle diffs
        if midOld.count * midNew.count <= 400_000 {
            let m = midOld.count
            let n = midNew.count
            var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
            if m > 0 && n > 0 {
                for i in stride(from: m - 1, through: 0, by: -1) {
                    for j in stride(from: n - 1, through: 0, by: -1) {
                        if midOld[i] == midNew[j] {
                            dp[i][j] = dp[i + 1][j + 1] + 1
                        } else {
                            dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                        }
                    }
                }
            }

            var i = 0
            var j = 0
            while i < m && j < n {
                if midOld[i] == midNew[j] {
                    result.append(AIDiffLine(
                        id: nextID,
                        kind: .unchanged,
                        oldLineNumber: prefixLen + i + 1,
                        newLineNumber: prefixLen + j + 1,
                        text: midOld[i]
                    ))
                    nextID += 1
                    i += 1
                    j += 1
                } else if dp[i + 1][j] >= dp[i][j + 1] {
                    result.append(AIDiffLine(
                        id: nextID,
                        kind: .removed,
                        oldLineNumber: prefixLen + i + 1,
                        newLineNumber: nil,
                        text: midOld[i]
                    ))
                    nextID += 1
                    removed += 1
                    i += 1
                } else {
                    result.append(AIDiffLine(
                        id: nextID,
                        kind: .added,
                        oldLineNumber: nil,
                        newLineNumber: prefixLen + j + 1,
                        text: midNew[j]
                    ))
                    nextID += 1
                    added += 1
                    j += 1
                }
            }
            while i < m {
                result.append(AIDiffLine(
                    id: nextID,
                    kind: .removed,
                    oldLineNumber: prefixLen + i + 1,
                    newLineNumber: nil,
                    text: midOld[i]
                ))
                nextID += 1
                removed += 1
                i += 1
            }
            while j < n {
                result.append(AIDiffLine(
                    id: nextID,
                    kind: .added,
                    oldLineNumber: nil,
                    newLineNumber: prefixLen + j + 1,
                    text: midNew[j]
                ))
                nextID += 1
                added += 1
                j += 1
            }
        } else {
            for (offset, line) in midOld.enumerated() {
                result.append(AIDiffLine(id: nextID, kind: .removed, oldLineNumber: prefixLen + offset + 1, newLineNumber: nil, text: line))
                nextID += 1
                removed += 1
            }
            for (offset, line) in midNew.enumerated() {
                result.append(AIDiffLine(id: nextID, kind: .added, oldLineNumber: nil, newLineNumber: prefixLen + offset + 1, text: line))
                nextID += 1
                added += 1
            }
        }

        // Suffix
        let suffixCount = oldLines.count - oldEnd
        for k in 0..<suffixCount {
            let oldIdx = oldEnd + k
            let newIdx = newEnd + k
            result.append(AIDiffLine(
                id: nextID,
                kind: .unchanged,
                oldLineNumber: oldIdx + 1,
                newLineNumber: newIdx + 1,
                text: oldLines[oldIdx]
            ))
            nextID += 1
        }

        return AIDiffResult(lines: result, addedCount: added, removedCount: removed)
    }

    /// Replaces a UTF-16 `NSRange` (matching `NSTextView.selectedRange()`) cleanly inside a document.
    public static func replacingRange(_ range: NSRange, in document: String, with replacement: String) -> String {
        let ns = document as NSString
        let safeLoc = min(max(0, range.location), ns.length)
        let safeLen = min(max(0, range.length), ns.length - safeLoc)
        return ns.replacingCharacters(in: NSRange(location: safeLoc, length: safeLen), with: replacement)
    }
}
