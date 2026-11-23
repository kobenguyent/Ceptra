import Foundation

public enum ArtifactScanner {
    public static func scan(outputDirectoryURL: URL) -> [ReportArtifact] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: outputDirectoryURL.path) else { return [] }

        let rootPath = outputDirectoryURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard let enumerator = fm.enumerator(
            at: outputDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [ReportArtifact] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            guard let kind = classify(extension: ext, fileName: fileURL.lastPathComponent) else {
                continue
            }

            let fullPath = fileURL.standardizedFileURL.path
            let relPath = fullPath.hasPrefix(prefix) ? String(fullPath.dropFirst(prefix.count)) : fileURL.lastPathComponent

            items.append(ReportArtifact(
                name: fileURL.lastPathComponent,
                relativePath: relPath,
                path: fullPath,
                kind: kind,
                fileSize: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? Date.distantPast
            ))
        }

        return items.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Scans multiple artifact directories (e.g. `test-results/` and `playwright-report/`),
    /// deduplicating by absolute path and sorting newest-first.
    public static func scan(directories: [URL]) -> [ReportArtifact] {
        var seen = Set<String>()
        var combined: [ReportArtifact] = []
        for dir in directories {
            for item in scan(outputDirectoryURL: dir) {
                if seen.insert(item.path).inserted {
                    combined.append(item)
                }
            }
        }
        return combined.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public static func newestJUnitXML(in outputDirectoryURL: URL, modifiedAfter cutoff: Date? = nil) -> URL? {
        let xmls = scan(outputDirectoryURL: outputDirectoryURL).filter { $0.kind == .junitXML }
        if let cutoff {
            if let fresh = xmls.first(where: { $0.modifiedAt >= cutoff.addingTimeInterval(-2) }) {
                return fresh.url
            }
        }
        return xmls.first?.url
    }

    public static func freshJUnitXMLs(in outputDirectoryURL: URL, modifiedAfter cutoff: Date) -> [URL] {
        let threshold = cutoff.addingTimeInterval(-2)
        return scan(outputDirectoryURL: outputDirectoryURL)
            .filter { $0.kind == .junitXML && $0.modifiedAt >= threshold }
            .map(\.url)
    }

    private static func classify(extension ext: String, fileName: String) -> ArtifactKind? {
        switch ext {
        case "png", "jpg", "jpeg", "webp":
            return .screenshot
        case "md":
            return .aiTrace
        case "webm", "mp4", "mov", "apng":
            return .screencast
        case "srt":
            return .subtitle
        case "xml":
            return .junitXML
        case "html", "htm":
            return .htmlReport
        case "aria", "har", "log", "txt":
            return .snapshot
        default:
            let lower = fileName.lowercased()
            if lower.contains("trace") && (ext == "json" || ext == "zip") {
                return .aiTrace
            }
            return nil
        }
    }
}
