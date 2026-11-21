import Foundation

public struct SourceMapOriginalPosition: Equatable, Hashable, Sendable {
    public let sourcePath: String
    public let line: Int // 1-based
    public let column: Int // 1-based

    public init(sourcePath: String, line: Int, column: Int) {
        self.sourcePath = sourcePath
        self.line = max(1, line)
        self.column = max(1, column)
    }
}

public struct SourceMapGeneratedPosition: Equatable, Hashable, Sendable {
    public let line: Int // 0-based (CDP)
    public let column: Int // 0-based (CDP)

    public init(line: Int, column: Int) {
        self.line = max(0, line)
        self.column = max(0, column)
    }
}

/// Zero-dependency SourceMap v3 VLQ decoder tailored for CodeceptJS 4.x `.temp.mjs` inline
/// source maps and standard external `.map` files.
public struct SourceMapV3: Sendable {
    public struct Segment: Sendable {
        public let generatedLine: Int // 0-based
        public let generatedColumn: Int // 0-based
        public let sourceIndex: Int
        public let originalLine: Int // 0-based
        public let originalColumn: Int // 0-based
    }

    public let resolvedSources: [String]
    private let segmentsByGeneratedLine: [Int: [Segment]]
    private let generatedByOriginal: [String: [Int: [Segment]]] // sourcePath -> originalLine(0-based) -> segments

    private static let base64Lookup: [Int] = {
        var table = [Int](repeating: -1, count: 128)
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        for (idx, ch) in chars.enumerated() {
            table[Int(ch)] = idx
        }
        return table
    }()

    public init?(jsonData: Data, scriptFileURL: URL?) {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let sources = obj["sources"] as? [String],
              let mappings = obj["mappings"] as? String else {
            return nil
        }

        let sourceRoot = (obj["sourceRoot"] as? String) ?? ""
        let baseDir = scriptFileURL?.deletingLastPathComponent()

        let resolved: [String] = sources.map { raw in
            let combined = sourceRoot.isEmpty ? raw : (sourceRoot.hasSuffix("/") ? sourceRoot + raw : sourceRoot + "/" + raw)
            if combined.hasPrefix("file://"), let url = URL(string: combined) {
                return url.standardizedFileURL.path
            }
            if combined.hasPrefix("/") {
                return URL(fileURLWithPath: combined).standardizedFileURL.path
            }
            if let baseDir {
                return baseDir.appendingPathComponent(combined).standardizedFileURL.path
            }
            return combined
        }

        var byGenLine: [Int: [Segment]] = [:]
        var byOrig: [String: [Int: [Segment]]] = [:]

        var genLine = 0
        var prevSourceIdx = 0
        var prevOrigLine = 0
        var prevOrigCol = 0

        let bytes = Array(mappings.utf8)
        var i = 0
        let count = bytes.count
        var genCol = 0

        while i < count {
            let b = bytes[i]
            if b == 59 { // ';'
                genLine += 1
                genCol = 0
                i += 1
                continue
            }
            if b == 44 { // ','
                i += 1
                continue
            }

            // Decode 1, 4, or 5 VLQ fields for this segment
            var fields: [Int] = []
            fields.reserveCapacity(5)
            while i < count && bytes[i] != 44 && bytes[i] != 59 {
                guard let (val, nextIdx) = Self.decodeVLQ(bytes: bytes, start: i) else {
                    i += 1
                    break
                }
                fields.append(val)
                i = nextIdx
            }

            if fields.isEmpty { continue }
            genCol += fields[0]

            if fields.count >= 4 {
                prevSourceIdx += fields[1]
                prevOrigLine += fields[2]
                prevOrigCol += fields[3]

                if prevSourceIdx >= 0 && prevSourceIdx < resolved.count {
                    let seg = Segment(
                        generatedLine: genLine,
                        generatedColumn: max(0, genCol),
                        sourceIndex: prevSourceIdx,
                        originalLine: max(0, prevOrigLine),
                        originalColumn: max(0, prevOrigCol)
                    )
                    byGenLine[genLine, default: []].append(seg)
                    let srcPath = resolved[prevSourceIdx]
                    byOrig[srcPath, default: [:]][seg.originalLine, default: []].append(seg)
                }
            }
        }

        self.resolvedSources = resolved
        self.segmentsByGeneratedLine = byGenLine
        self.generatedByOriginal = byOrig
    }

    /// Parses an inline `data:application/json;...;base64,...` sourceMapURL or a relative/file `.map` path.
    public static func decode(sourceMapURL: String, scriptURLString: String?) -> SourceMapV3? {
        let scriptFileURL: URL? = {
            guard let s = scriptURLString else { return nil }
            if s.hasPrefix("file://") { return URL(string: s) }
            if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
            return nil
        }()

        let trimmed = sourceMapURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:") {
            guard let commaIdx = trimmed.firstIndex(of: ",") else { return nil }
            let header = trimmed[..<commaIdx].lowercased()
            let payload = String(trimmed[trimmed.index(after: commaIdx)...])
            if header.contains(";base64") {
                guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
                    return nil
                }
                return SourceMapV3(jsonData: data, scriptFileURL: scriptFileURL)
            } else if let decoded = payload.removingPercentEncoding,
                      let data = decoded.data(using: .utf8) {
                return SourceMapV3(jsonData: data, scriptFileURL: scriptFileURL)
            }
            return nil
        }

        // External .map file next to script
        let mapFileURL: URL?
        if trimmed.hasPrefix("file://") {
            mapFileURL = URL(string: trimmed)
        } else if trimmed.hasPrefix("/") {
            mapFileURL = URL(fileURLWithPath: trimmed)
        } else if let base = scriptFileURL?.deletingLastPathComponent() {
            mapFileURL = base.appendingPathComponent(trimmed)
        } else {
            mapFileURL = nil
        }

        guard let mapFileURL, let data = try? Data(contentsOf: mapFileURL) else {
            return nil
        }
        return SourceMapV3(jsonData: data, scriptFileURL: scriptFileURL)
    }

    /// Maps 0-based CDP generated (line, column) back to 1-based original source position.
    public func originalPosition(generatedLine: Int, generatedColumn: Int) -> SourceMapOriginalPosition? {
        guard let lineSegments = segmentsByGeneratedLine[generatedLine], !lineSegments.isEmpty else {
            return nil
        }
        // Find greatest segment with generatedColumn <= target column
        var best = lineSegments[0]
        for seg in lineSegments {
            if seg.generatedColumn <= generatedColumn {
                best = seg
            } else {
                break
            }
        }
        guard best.sourceIndex >= 0 && best.sourceIndex < resolvedSources.count else { return nil }
        return SourceMapOriginalPosition(
            sourcePath: resolvedSources[best.sourceIndex],
            line: best.originalLine + 1,
            column: best.originalColumn + 1
        )
    }

    /// Maps a 1-based original source line in `originalFilePath` to the earliest 0-based CDP generated position.
    public func generatedPosition(forOriginalFile originalFilePath: String, oneBasedLine: Int) -> SourceMapGeneratedPosition? {
        let normalized = URL(fileURLWithPath: originalFilePath).standardizedFileURL.path
        guard let lineMap = generatedByOriginal[normalized] else { return nil }
        let zeroBased = max(0, oneBasedLine - 1)
        if let exact = lineMap[zeroBased]?.first {
            return SourceMapGeneratedPosition(line: exact.generatedLine, column: exact.generatedColumn)
        }
        // Fallback: find the nearest subsequent mapped line within 3 lines (e.g. blank/comment line)
        for delta in 1...3 {
            if let next = lineMap[zeroBased + delta]?.first {
                return SourceMapGeneratedPosition(line: next.generatedLine, column: next.generatedColumn)
            }
        }
        return nil
    }

    private static func decodeVLQ(bytes: [UInt8], start: Int) -> (Int, Int)? {
        var result = 0
        var shift = 0
        var idx = start
        let count = bytes.count

        while idx < count {
            let b = Int(bytes[idx])
            guard b < 128 else { return nil }
            let digit = base64Lookup[b]
            guard digit >= 0 else { return nil }
            idx += 1

            let continuation = (digit & 32) != 0
            result += (digit & 31) << shift
            shift += 5

            if !continuation {
                let isNeg = (result & 1) == 1
                let value = result >> 1
                return (isNeg ? -value : value, idx)
            }
            if shift > 30 { return nil }
        }
        return nil
    }
}
