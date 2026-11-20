import Foundation

public struct WorkspaceTreeNode: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let relativePath: String
    public let name: String
    public let isDirectory: Bool
    public let isHidden: Bool
    public let isBinary: Bool
    public let file: WorkspaceFile?
    public let children: [WorkspaceTreeNode]
    public let testFileCount: Int
    public let scenarioCount: Int

    public init(
        path: String,
        relativePath: String,
        name: String,
        isDirectory: Bool,
        isHidden: Bool = false,
        isBinary: Bool = false,
        file: WorkspaceFile? = nil,
        children: [WorkspaceTreeNode] = [],
        testFileCount: Int = 0,
        scenarioCount: Int = 0
    ) {
        self.path = path
        self.relativePath = relativePath
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isBinary = isBinary
        self.file = file
        self.children = children
        self.testFileCount = testFileCount
        self.scenarioCount = scenarioCount
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    /// Returns a pruned copy of this subtree matching `query` and/or `tag`, preserving ancestor folders.
    public func filtered(query rawQuery: String, tag: String?) -> WorkspaceTreeNode? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasQuery = !query.isEmpty
        let hasTag = tag != nil

        if !hasQuery && !hasTag {
            return self
        }

        if isDirectory {
            let matchingChildren = children.compactMap { $0.filtered(query: query, tag: tag) }
            let dirNameMatches = hasQuery && !hasTag && (name.lowercased().contains(query) || relativePath.lowercased().contains(query))
            if dirNameMatches && matchingChildren.isEmpty {
                return self
            }
            guard !matchingChildren.isEmpty else { return nil }
            let tests = matchingChildren.reduce(0) { $0 + $1.testFileCount }
            let scenarios = matchingChildren.reduce(0) { $0 + $1.scenarioCount }
            return WorkspaceTreeNode(
                path: path,
                relativePath: relativePath,
                name: name,
                isDirectory: true,
                isHidden: isHidden,
                isBinary: false,
                file: nil,
                children: matchingChildren,
                testFileCount: tests,
                scenarioCount: scenarios
            )
        } else {
            if let tag {
                guard let file, file.allTags.contains(tag) else { return nil }
            }
            if !hasQuery {
                return self
            }
            if name.lowercased().contains(query) || relativePath.lowercased().contains(query) {
                return self
            }
            if let file, file.features.contains(where: { feature in
                feature.title.lowercased().contains(query) ||
                feature.scenarios.contains(where: { $0.title.lowercased().contains(query) })
            }) {
                return self
            }
            return nil
        }
    }

    /// Collects all directory paths inside this subtree (useful for Expand All).
    public func allDirectoryPaths() -> [String] {
        var result: [String] = []
        if isDirectory {
            result.append(path)
            for child in children where child.isDirectory {
                result.append(contentsOf: child.allDirectoryPaths())
            }
        }
        return result
    }

    /// Collects relative directory paths inside this subtree (useful for folder pickers).
    public func allDirectoryRelativePaths() -> [String] {
        var result: [String] = []
        if isDirectory {
            result.append(relativePath)
            for child in children where child.isDirectory {
                result.append(contentsOf: child.allDirectoryRelativePaths())
            }
        }
        return result
    }

    /// Returns the ancestor directory paths leading to `targetPath` (works for both files and folders).
    public func ancestorDirectoryPaths(containing targetPath: String) -> [String]? {
        if path == targetPath {
            return isDirectory ? [path] : []
        }
        guard isDirectory else { return nil }
        for child in children {
            if let found = child.ancestorDirectoryPaths(containing: targetPath) {
                return [path] + found
            }
        }
        return nil
    }
}
