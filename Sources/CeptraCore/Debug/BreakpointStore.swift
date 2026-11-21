import Foundation

/// Persists workspace breakpoints and watch expressions locally in UserDefaults
/// without creating any files inside the user's CodeceptJS repository.
public final class BreakpointStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let breakpointsKey = "com.kobenguyent.Ceptra.breakpoints.v1"
    private let watchesKey = "com.kobenguyent.Ceptra.watches.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadBreakpoints(forWorkspaceRoot rootPath: String) -> [DebugBreakpoint] {
        let normalized = Self.normalizePath(rootPath)
        guard let data = defaults.data(forKey: breakpointsKey),
              let map = try? JSONDecoder().decode([String: [DebugBreakpoint]].self, from: data) else {
            return []
        }
        return (map[normalized] ?? []).sorted {
            if $0.filePath == $1.filePath { return $0.line < $1.line }
            return $0.filePath < $1.filePath
        }
    }

    public func saveBreakpoints(_ breakpoints: [DebugBreakpoint], forWorkspaceRoot rootPath: String) {
        let normalized = Self.normalizePath(rootPath)
        var map: [String: [DebugBreakpoint]] = [:]
        if let data = defaults.data(forKey: breakpointsKey),
           let existing = try? JSONDecoder().decode([String: [DebugBreakpoint]].self, from: data) {
            map = existing
        }
        if breakpoints.isEmpty {
            map.removeValue(forKey: normalized)
        } else {
            map[normalized] = breakpoints
        }
        if let encoded = try? JSONEncoder().encode(map) {
            defaults.set(encoded, forKey: breakpointsKey)
        }
    }

    public func loadWatchExpressions(forWorkspaceRoot rootPath: String) -> [String] {
        let normalized = Self.normalizePath(rootPath)
        guard let data = defaults.data(forKey: watchesKey),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return []
        }
        return map[normalized] ?? []
    }

    public func saveWatchExpressions(_ expressions: [String], forWorkspaceRoot rootPath: String) {
        let normalized = Self.normalizePath(rootPath)
        var map: [String: [String]] = [:]
        if let data = defaults.data(forKey: watchesKey),
           let existing = try? JSONDecoder().decode([String: [String]].self, from: data) {
            map = existing
        }
        let cleaned = expressions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cleaned.isEmpty {
            map.removeValue(forKey: normalized)
        } else {
            map[normalized] = cleaned
        }
        if let encoded = try? JSONEncoder().encode(map) {
            defaults.set(encoded, forKey: watchesKey)
        }
    }

    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
