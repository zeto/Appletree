import Foundation

public struct Mark: Sendable, Equatable, Identifiable {
    public var path: String
    public var bytes: UInt64
    public var hidden: Bool

    public var id: String { path }

    public init(path: String, bytes: UInt64, hidden: Bool = false) {
        self.path = normalize(path: path)
        self.bytes = bytes
        self.hidden = hidden
    }
}

public struct MarkSet: Sendable, Equatable {
    public private(set) var marks: [Mark]

    public init(marks: [Mark] = []) {
        self.marks = marks
    }

    public var bytes: UInt64 { marks.reduce(0) { $0 + $1.bytes } }

    public func contains(_ path: String) -> Bool {
        let path = normalize(path: path)
        return marks.contains { $0.path == path }
    }

    /// The marked directory that already covers `path`, if marking `path` itself would be redundant.
    public func covering(_ path: String) -> Mark? {
        let path = normalize(path: path)
        return marks.first { $0.path != path && isWithin(path, $0.path) }
    }

    public mutating func toggle(_ mark: Mark) {
        let path = mark.path
        if let cover = covering(path) {
            marks.removeAll { $0.path == cover.path }
            return
        }
        if let index = marks.firstIndex(where: { $0.path == path }) {
            marks.remove(at: index)
            return
        }
        marks.removeAll { isWithin($0.path, path) }
        marks.append(mark)
        marks.sort { $0.path < $1.path }
    }

    public mutating func remove(_ path: String) {
        let path = normalize(path: path)
        marks.removeAll { $0.path == path }
    }

    public mutating func removeAll() {
        marks.removeAll()
    }

    /// Re-read sizes from a fresh tree and drop paths that are gone.
    public func refreshed(rootPath: String, tree: Node) -> MarkSet {
        var kept: [Mark] = []
        for mark in marks {
            guard isWithin(mark.path, rootPath) else { continue }
            let relative = relativeCrumbs(rootPath: rootPath, path: mark.path, tree: tree)
            guard let crumbs = relative, let node = tree.resolve(crumbs) else { continue }
            kept.append(Mark(path: mark.path, bytes: node.bytes, hidden: mark.hidden))
        }
        return MarkSet(marks: kept)
    }

    public func targets() -> [Target] {
        marks.map { Target(path: $0.path, bytes: $0.bytes, hidden: $0.hidden) }
    }
}

public func relativeCrumbs(rootPath: String, path: String, tree: Node) -> [Int]? {
    let rootPath = normalize(path: rootPath)
    let path = normalize(path: path)
    guard isWithin(path, rootPath) else { return nil }
    if path == rootPath { return [] }
    let prefix = rootPath == "/" ? "/" : rootPath + "/"
    guard path.hasPrefix(prefix) else { return nil }
    let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    var crumbs: [Int] = []
    var node = tree
    for part in parts {
        guard let index = node.children.firstIndex(where: { $0.name == part }) else { return nil }
        crumbs.append(index)
        node = node.children[index]
    }
    return crumbs
}
