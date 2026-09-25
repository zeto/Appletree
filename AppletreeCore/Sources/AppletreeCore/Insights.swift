import Foundation

public let staleDays: Int64 = 30
private let day: Int64 = 86_400
private let minimumFindingBytes: UInt64 = 64 * 1024 * 1024

public enum Finding: Sendable, Equatable {
    case reclaimable(Reclaim)
    case worktrees(count: Int, oldestDays: Int64)
    case staleExperiments(count: Int)

    public var label: String {
        switch self {
        case .reclaimable(let reason):
            reason.label
        case .worktrees(let count, let oldest):
            "\(count) worktrees, oldest \(oldest)d"
        case .staleExperiments(let count):
            "\(count) stale experiments"
        }
    }
}

public struct Candidate: Sendable, Equatable, Identifiable {
    public var crumbs: [Int]
    public var bytes: UInt64
    public var finding: Finding

    public var id: String { crumbs.map(String.init).joined(separator: ".") + finding.label }

    public init(crumbs: [Int], bytes: UInt64, finding: Finding) {
        self.crumbs = crumbs
        self.bytes = bytes
        self.finding = finding
    }
}

public func worthALook(root: Node, now: Int64, limit: Int) -> [Candidate] {
    var found: [Candidate] = []
    var crumbs: [Int] = []
    for (index, child) in root.children.enumerated() {
        crumbs.append(index)
        visit(child, crumbs: &crumbs, now: now, found: &found)
        crumbs.removeLast()
    }
    found.removeAll { $0.bytes < minimumFindingBytes }
    found.sort { $0.bytes > $1.bytes }
    if found.count > limit {
        found.removeLast(found.count - limit)
    }
    return found
}

private func visit(_ node: Node, crumbs: inout [Int], now: Int64, found: inout [Candidate]) {
    guard node.isDirectory else { return }
    if let reason = node.reclaim {
        found.append(Candidate(crumbs: crumbs, bytes: node.bytes, finding: .reclaimable(reason)))
        return
    }
    let name = node.name.lowercased()
    if node.category == .agentScratch, name == "worktrees" {
        let trees = node.children.filter(\.isDirectory)
        if !trees.isEmpty {
            let oldest = trees.map(\.modified).filter { $0 > 0 }.min() ?? now
            found.append(Candidate(
                crumbs: crumbs,
                bytes: node.bytes,
                finding: .worktrees(count: trees.count, oldestDays: max(0, now - oldest) / day)
            ))
            return
        }
    }
    let experiments = node.category == .agentScratch && (name == "tries" || name == "experiments")
    var staleCount = 0
    var staleBytes: UInt64 = 0
    for (index, child) in node.children.enumerated() {
        let isStale = experiments && child.isDirectory && child.modified > 0 && now - child.modified > staleDays * day
        if isStale {
            staleCount += 1
            staleBytes += child.bytes
            continue
        }
        crumbs.append(index)
        visit(child, crumbs: &crumbs, now: now, found: &found)
        crumbs.removeLast()
    }
    if staleCount > 0 {
        found.append(Candidate(
            crumbs: crumbs,
            bytes: staleBytes,
            finding: .staleExperiments(count: staleCount)
        ))
    }
}
