import Foundation

public enum Keep: Sendable, Equatable {
    case whole
    case partial(bytes: UInt64, files: UInt64)
}

public struct Matches: Sendable, Equatable {
    public var needle: String
    public var base: [Int]
    public var keep: [[Int]: Keep]
    public var count: Int
    public var bytes: UInt64
    public var files: UInt64

    public init(
        needle: String,
        base: [Int] = [],
        keep: [[Int]: Keep] = [:],
        count: Int = 0,
        bytes: UInt64 = 0,
        files: UInt64 = 0
    ) {
        self.needle = needle
        self.base = base
        self.keep = keep
        self.count = count
        self.bytes = bytes
        self.files = files
    }

    public func keep(at crumbs: [Int]) -> Keep? {
        if !crumbs.starts(with: base) {
            return .whole
        }
        for length in base.count...crumbs.count {
            let prefix = Array(crumbs.prefix(length))
            switch keep[prefix] {
            case .whole:
                return .whole
            case .partial? where length == crumbs.count:
                return keep[prefix]
            case nil where length > base.count:
                return nil
            default:
                break
            }
        }
        return .partial(bytes: bytes, files: files)
    }

    public static func value(_ keep: Keep, node: Node, metric: Metric) -> UInt64 {
        switch (keep, metric) {
        case (.whole, _):
            return node.value(metric)
        case (.partial(let bytes, _), .bytes):
            return bytes
        case (.partial(_, let files), .files):
            return files
        }
    }
}

public func filter(node: Node, base: [Int] = [], needle: String) -> Matches? {
    let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if needle.isEmpty { return nil }
    var matches = Matches(needle: needle, base: base)
    var crumbs = base
    let totals = visit(node, crumbs: &crumbs, matches: &matches)
    matches.bytes = totals.0
    matches.files = totals.1
    return matches
}

private func visit(_ node: Node, crumbs: inout [Int], matches: inout Matches) -> (UInt64, UInt64) {
    var total = (UInt64(0), UInt64(0))
    for (index, child) in node.children.enumerated() {
        crumbs.append(index)
        if child.name.range(of: matches.needle, options: .caseInsensitive) != nil {
            matches.keep[crumbs] = .whole
            matches.count += 1
            total.0 += child.bytes
            total.1 += child.files
        } else if !child.children.isEmpty {
            let (bytes, files) = visit(child, crumbs: &crumbs, matches: &matches)
            if bytes > 0 || files > 0 {
                matches.keep[crumbs] = .partial(bytes: bytes, files: files)
                total.0 += bytes
                total.1 += files
            }
        }
        crumbs.removeLast()
    }
    return total
}
