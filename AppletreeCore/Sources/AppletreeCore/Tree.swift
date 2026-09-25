import Foundation

public enum NodeKind: String, Sendable, Equatable, Hashable {
    case directory
    case file
    case symlink
    case other
}

public enum Metric: String, Sendable, Equatable, Hashable, CaseIterable {
    case bytes
    case files

    public var label: String {
        switch self {
        case .bytes: "Size"
        case .files: "Files"
        }
    }

    public var toggled: Metric {
        switch self {
        case .bytes: .files
        case .files: .bytes
        }
    }
}

public struct InodeKey: Sendable, Equatable, Hashable {
    public var fsid: UInt64
    public var fileID: UInt64

    public init(fsid: UInt64, fileID: UInt64) {
        self.fsid = fsid
        self.fileID = fileID
    }
}

public struct Node: Sendable, Equatable {
    public var name: String
    public var kind: NodeKind
    public var bytes: UInt64
    public var ownBytes: UInt64
    public var files: UInt64
    public var ownFiles: UInt64
    public var dirs: UInt64
    public var inode: InodeKey?
    public var readError: Bool
    public var modified: Int64
    public var category: Category
    public var reclaim: Reclaim?
    public var dataless: Bool
    public var children: [Node]

    public init(
        name: String,
        kind: NodeKind,
        bytes: UInt64 = 0,
        ownBytes: UInt64 = 0,
        files: UInt64 = 0,
        ownFiles: UInt64 = 0,
        dirs: UInt64 = 0,
        inode: InodeKey? = nil,
        readError: Bool = false,
        modified: Int64 = 0,
        category: Category = .other,
        reclaim: Reclaim? = nil,
        dataless: Bool = false,
        children: [Node] = []
    ) {
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.ownBytes = ownBytes
        self.files = files
        self.ownFiles = ownFiles
        self.dirs = dirs
        self.inode = inode
        self.readError = readError
        self.modified = modified
        self.category = category
        self.reclaim = reclaim
        self.dataless = dataless
        self.children = children
    }

    public static func directory(_ name: String) -> Node {
        Node(name: name, kind: .directory, dirs: 1)
    }

    public static func entry(_ name: String, kind: NodeKind, bytes: UInt64) -> Node {
        Node(
            name: name,
            kind: kind,
            bytes: bytes,
            ownBytes: bytes,
            files: kind == .file ? 1 : 0,
            ownFiles: kind == .file ? 1 : 0
        )
    }

    public var isDirectory: Bool { kind == .directory }

    public func value(_ metric: Metric) -> UInt64 {
        switch metric {
        case .bytes: bytes
        case .files: files
        }
    }

    public func child(named name: String) -> Node? {
        children.first { $0.name == name }
    }

    /// Child indexes from this node. They address the tree they were built from.
    public func resolve(_ crumbs: [Int]) -> Node? {
        var node = self
        for index in crumbs {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }

    public func resolveChain(_ crumbs: [Int]) -> [Node] {
        var chain = [self]
        var node = self
        for index in crumbs {
            guard node.children.indices.contains(index) else { break }
            node = node.children[index]
            chain.append(node)
        }
        return chain
    }

    public var largestChild: Int? {
        children.isEmpty ? nil : 0
    }

    public var depth: Int {
        children.map(\.depth).max().map { $0 + 1 } ?? 0
    }

    public func find(_ needle: String) -> [Int]? {
        let needle = needle.lowercased()
        if needle.isEmpty { return nil }
        var queue: [[Int]] = [[]]
        var head = 0
        while head < queue.count {
            let crumbs = queue[head]
            head += 1
            guard let node = resolve(crumbs) else { continue }
            for (index, child) in node.children.enumerated() {
                if child.name.lowercased().contains(needle) {
                    return crumbs + [index]
                }
                if child.isDirectory, !child.children.isEmpty {
                    queue.append(crumbs + [index])
                }
            }
        }
        return nil
    }
}

/// Recompute totals from children, then order children largest-first.
///
/// `ownBytes` and `ownFiles` are derived here. Hardlink de-duplication zeros a
/// leaf's `ownBytes` and this pass carries that into every total above it.
public func aggregate(_ node: inout Node, metric: Metric) {
    if !node.isDirectory {
        node.bytes = node.ownBytes
        node.files = node.ownFiles
        node.dirs = 0
        return
    }

    var bytes: UInt64 = 0
    var files: UInt64 = 0
    var ownBytes: UInt64 = 0
    var ownFiles: UInt64 = 0
    var dirs: UInt64 = 1
    var modified = node.modified
    for index in node.children.indices {
        aggregate(&node.children[index], metric: metric)
        let child = node.children[index]
        modified = max(modified, child.modified)
        bytes += child.bytes
        files += child.files
        dirs += child.dirs
        if !child.isDirectory {
            ownBytes += child.bytes
            ownFiles += child.files
        }
    }
    node.bytes = bytes
    node.files = files
    node.ownBytes = ownBytes
    node.ownFiles = ownFiles
    node.dirs = dirs
    node.modified = modified
    node.children.sort { lhs, rhs in
        let left = lhs.value(metric)
        let right = rhs.value(metric)
        if left != right { return left > right }
        return lhs.name < rhs.name
    }
}

public func path(ofRoot rootPath: String, node: Node, crumbs: [Int]) -> String {
    var path = rootPath
    var current = node
    for index in crumbs {
        guard current.children.indices.contains(index) else { break }
        current = current.children[index]
        path = join(path, current.name)
    }
    return path
}

/// Collapse `.` and `..` without touching the filesystem, so a symlink cannot redirect a guard.
public func normalize(path: String) -> String {
    let absolute = path.hasPrefix("/")
    var parts: [String] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
        if part == "." { continue }
        if part == ".." {
            if let last = parts.last, last != ".." {
                parts.removeLast()
            } else if !absolute {
                parts.append("..")
            }
            continue
        }
        parts.append(String(part))
    }
    if absolute {
        return "/" + parts.joined(separator: "/")
    }
    if parts.isEmpty { return "." }
    return parts.joined(separator: "/")
}

public func join(_ root: String, _ name: String) -> String {
    if root == "/" { return "/" + name }
    return root + "/" + name
}

public func isWithin(_ path: String, _ root: String) -> Bool {
    let path = normalize(path: path)
    let root = normalize(path: root)
    if root == "/" { return path.hasPrefix("/") }
    return path == root || path.hasPrefix(root + "/")
}

public func parentPath(_ path: String) -> String? {
    let path = normalize(path: path)
    if path == "/" { return nil }
    return normalize(path: URL(fileURLWithPath: path).deletingLastPathComponent().path)
}
