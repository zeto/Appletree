import Darwin
import Foundation
import os

public struct ScanOptions: Sendable, Equatable {
    public var apparentSize: Bool
    public var followLinks: Bool
    public var includeHidden: Bool
    public var dedupHardlinks: Bool
    public var metric: Metric
    public var maxDepth: Int?
    public var volumePolicy: VolumePolicy

    public init(
        apparentSize: Bool = false,
        followLinks: Bool = false,
        includeHidden: Bool = true,
        dedupHardlinks: Bool = true,
        metric: Metric = .bytes,
        maxDepth: Int? = nil,
        volumePolicy: VolumePolicy = .oneVolume
    ) {
        self.apparentSize = apparentSize
        self.followLinks = followLinks
        self.includeHidden = includeHidden
        self.dedupHardlinks = dedupHardlinks
        self.metric = metric
        self.maxDepth = maxDepth
        self.volumePolicy = volumePolicy
    }
}

extension ScanOptions {
    /// Measurement settings that must match before a finished tree can be spliced into a wider scan.
    public func sameMeasurement(as other: ScanOptions) -> Bool {
        apparentSize == other.apparentSize
            && followLinks == other.followLinks
            && includeHidden == other.includeHidden
            && dedupHardlinks == other.dedupHardlinks
            && maxDepth == other.maxDepth
            && volumePolicy == other.volumePolicy
    }
}

public struct Known: Sendable {
    public var path: String
    public var options: ScanOptions
    public var tree: Node

    public init(path: String, options: ScanOptions, tree: Node) {
        self.path = path
        self.options = options
        self.tree = tree
    }
}

public struct ScanSnapshot: Sendable, Equatable {
    public var files: UInt64
    public var directories: UInt64
    public var errors: UInt64
    public var messages: [String]
    public var finished: Bool
    public var cancelled: Bool

    public init(
        files: UInt64 = 0,
        directories: UInt64 = 0,
        errors: UInt64 = 0,
        messages: [String] = [],
        finished: Bool = false,
        cancelled: Bool = false
    ) {
        self.files = files
        self.directories = directories
        self.errors = errors
        self.messages = messages
        self.finished = finished
        self.cancelled = cancelled
    }
}

public enum ScanError: Error, Equatable, LocalizedError {
    case notDirectory(String)
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notDirectory(let path): "\(path) is not a directory"
        case .cancelled: "Scan cancelled"
        case .failed(let message): message
        }
    }
}

public final class ScanHandle: @unchecked Sendable {
    private let coordinator: ScanCoordinator

    fileprivate init(coordinator: ScanCoordinator) {
        self.coordinator = coordinator
    }

    public func snapshot() -> ScanSnapshot { coordinator.snapshot() }
    public func cancel() { coordinator.cancel() }
    public var isFinished: Bool { coordinator.isFinished }

    public func wait() throws -> Node {
        try coordinator.wait()
    }
}

public func scan(
    root: URL,
    options: ScanOptions = ScanOptions(),
    known: Known? = nil
) throws -> Node {
    let handle = try ScanHandle.start(root: root, options: options, known: known)
    return try handle.wait()
}

extension ScanHandle {
    public static func start(root: URL, options: ScanOptions = ScanOptions(), known: Known? = nil) throws -> ScanHandle {
        let path = normalize(path: root.path)
        var st = stat()
        if lstat(path, &st) != 0 {
            throw ScanError.failed(String(cString: strerror(errno)))
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            throw ScanError.notDirectory(path)
        }
        let boundary = options.volumePolicy == .unrestricted
            ? VolumeBoundary()
            : liveBoundary(root: path, policy: options.volumePolicy)
        let reusable = known.flatMap { item in
            item.options.sameMeasurement(as: options) ? item : nil
        }
        let coordinator = ScanCoordinator(
            rootPath: path,
            rootModified: Int64(st.st_mtimespec.tv_sec),
            options: options,
            boundary: boundary,
            known: reusable
        )
        coordinator.start()
        return ScanHandle(coordinator: coordinator)
    }
}

/// The directory's own listing holds the initial count of 1. Each subdirectory
/// adds one before its task is created. The node is built only when the count
/// reaches zero, so a fast child cannot finish the parent before a sibling exists.
private final class PendingDir: @unchecked Sendable {
    let path: String
    let name: String
    let parent: PendingDir?
    let depth: Int
    let modified: Int64
    let pending = OSAllocatedUnfairLock(initialState: 1)
    let children = OSAllocatedUnfairLock(initialState: [Node]())
    let readError = OSAllocatedUnfairLock(initialState: false)
    let adopted = OSAllocatedUnfairLock<Node?>(initialState: nil)

    init(path: String, name: String, parent: PendingDir?, depth: Int, modified: Int64) {
        self.path = path
        self.name = name
        self.parent = parent
        self.depth = depth
        self.modified = modified
    }

    func addChildTask() {
        pending.withLock { $0 += 1 }
    }

    func finish(_ coordinator: ScanCoordinator) {
        let done = pending.withLock { state -> Bool in
            state -= 1
            return state == 0
        }
        guard done else { return }
        let node = build()
        if let parent {
            parent.children.withLock { $0.append(node) }
            parent.finish(coordinator)
        } else {
            coordinator.setRoot(node)
        }
    }

    private func build() -> Node {
        if let adopted = adopted.withLock({ $0 }) {
            var node = adopted
            node.name = name
            return node
        }
        var node = Node.directory(name)
        node.children = children.withLock { $0 }
        node.readError = readError.withLock { $0 }
        node.modified = modified
        return node
    }
}

private final class ScanCoordinator: @unchecked Sendable {
    let rootPath: String
    let options: ScanOptions
    let boundary: VolumeBoundary
    let known: Known?
    private let rootModified: Int64
    private let queue: OperationQueue
    private let group = DispatchGroup()
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let finished = OSAllocatedUnfairLock(initialState: false)
    private let rootNode = OSAllocatedUnfairLock<Node?>(initialState: nil)
    private let files = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let directories = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let errors = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let messages = OSAllocatedUnfairLock(initialState: [String]())
    private let visited = OSAllocatedUnfairLock(initialState: Set<InodeKey>())
    private let failure = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(rootPath: String, rootModified: Int64, options: ScanOptions, boundary: VolumeBoundary, known: Known?) {
        self.rootPath = rootPath
        self.rootModified = rootModified
        self.options = options
        self.boundary = boundary
        self.known = known
        let queue = OperationQueue()
        queue.name = "appletree.scan"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        self.queue = queue
    }

    func start() {
        let root = PendingDir(
            path: rootPath,
            name: rootPath == "/" ? "/" : URL(fileURLWithPath: rootPath).lastPathComponent,
            parent: nil,
            depth: 0,
            modified: rootModified
        )
        directories.withLock { $0 += 1 }
        group.enter()
        queue.addOperation { [self] in
            self.walk(root)
            self.group.leave()
        }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    var isCancelled: Bool { cancelled.withLock { $0 } }
    var isFinished: Bool { finished.withLock { $0 } }

    func snapshot() -> ScanSnapshot {
        ScanSnapshot(
            files: files.withLock { $0 },
            directories: directories.withLock { $0 },
            errors: errors.withLock { $0 },
            messages: messages.withLock { $0 },
            finished: finished.withLock { $0 },
            cancelled: cancelled.withLock { $0 }
        )
    }

    func setRoot(_ node: Node) {
        rootNode.withLock { $0 = node }
    }

    func wait() throws -> Node {
        group.wait()
        finished.withLock { $0 = true }
        if isCancelled { throw ScanError.cancelled }
        if let message = failure.withLock({ $0 }) {
            throw ScanError.failed(message)
        }
        guard var node = rootNode.withLock({ $0 }) else {
            throw ScanError.failed(rootPath)
        }
        if rootPath == "/" {
            node.name = "/"
        }
        if options.dedupHardlinks {
            var charged = Set<InodeKey>()
            chargeHardlinks(&node, charged: &charged)
        }
        aggregate(&node, metric: options.metric)
        classify(&node)
        return node
    }

    private func noteError(_ path: String, _ message: String) {
        errors.withLock { $0 += 1 }
        messages.withLock { list in
            if list.count < 50 {
                list.append("\(path): \(message)")
            }
        }
    }

    private func walk(_ dir: PendingDir) {
        defer { dir.finish(self) }
        if isCancelled { return }
        if let known, normalize(path: known.path) == dir.path {
            dir.adopted.withLock { $0 = known.tree }
            return
        }
        if options.followLinks {
            let identity = directoryIdentity(dir.path)
            if let identity {
                let inserted = visited.withLock { $0.insert(identity).inserted }
                if !inserted { return }
            }
        }
        switch listDirectory(dir.path) {
        case .unreadable(let message):
            dir.readError.withLock { $0 = true }
            noteError(dir.path, message)
        case .entries(let entries):
            consume(entries, in: dir)
        }
    }

    private func consume(_ entries: [BulkEntry], in dir: PendingDir) {
        let stopDescending = options.maxDepth.map { dir.depth >= $0 } ?? false
        var leaves: [Node] = []
        for entry in entries {
            if isCancelled { break }
            if entry.error != 0 {
                noteError(join(dir.path, entry.name), String(cString: strerror(entry.error)))
                continue
            }
            let hidden = entry.name.hasPrefix(".") || entry.flags & hiddenFlag() != 0
            if !options.includeHidden && hidden { continue }
            let childPath = join(dir.path, entry.name)
            let kind = nodeKind(of: entry.objectType)
            if kind == .directory {
                if stopDescending { continue }
                let fsid = entry.hasFSID ? entry.fsid : 0
                if !shouldEnter(path: childPath, fsid: fsid, boundary: boundary) { continue }
                enqueue(path: childPath, name: entry.name, parent: dir, depth: dir.depth + 1, modified: entry.modified)
                continue
            }
            if kind == .symlink, options.followLinks, follow(entry, path: childPath, parent: dir, leaves: &leaves) {
                continue
            }
            leaves.append(leaf(entry, kind: kind))
        }
        if !leaves.isEmpty {
            let count = UInt64(leaves.count)
            let found = leaves
            files.withLock { $0 += count }
            dir.children.withLock { $0.append(contentsOf: found) }
        }
    }

    private func enqueue(path: String, name: String, parent: PendingDir, depth: Int, modified: Int64) {
        parent.addChildTask()
        directories.withLock { $0 += 1 }
        let child = PendingDir(path: path, name: name, parent: parent, depth: depth, modified: modified)
        group.enter()
        queue.addOperation { [self] in
            self.walk(child)
            self.group.leave()
        }
    }

    /// Returns true when the symlink was turned into a followed file or directory.
    private func follow(_ entry: BulkEntry, path: String, parent: PendingDir, leaves: inout [Node]) -> Bool {
        var st = stat()
        if stat(path, &st) != 0 {
            leaves.append(leaf(entry, kind: .symlink))
            return true
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            let fsid = fsidOf(path: path) ?? entry.fsid
            guard shouldEnter(path: path, fsid: fsid, boundary: boundary) else { return true }
            if options.maxDepth.map({ parent.depth >= $0 }) ?? false { return true }
            enqueue(path: path, name: entry.name, parent: parent, depth: parent.depth + 1, modified: entry.modified)
            return true
        }
        var node = Node.entry(entry.name, kind: .file, bytes: measured(length: st.st_size, allocated: Int64(st.st_blocks) * 512))
        node.modified = Int64(st.st_mtimespec.tv_sec)
        node.inode = InodeKey(fsid: fsidOf(path: path) ?? entry.fsid, fileID: st.st_ino)
        node.dataless = entry.flags & datalessFlag() != 0
        leaves.append(node)
        return true
    }

    private func leaf(_ entry: BulkEntry, kind: NodeKind) -> Node {
        let bytes = measured(length: entry.length, allocated: entry.allocated)
        var node = Node.entry(entry.name, kind: kind, bytes: bytes)
        node.modified = entry.modified
        if entry.hasFSID, entry.fileID != 0 {
            node.inode = InodeKey(fsid: entry.fsid, fileID: entry.fileID)
        }
        node.dataless = entry.flags & datalessFlag() != 0
        return node
    }

    private func measured(length: Int64, allocated: Int64) -> UInt64 {
        if options.apparentSize {
            return UInt64(max(0, length))
        }
        if allocated > 0 { return UInt64(allocated) }
        return UInt64(max(0, length))
    }

    /// `stat` follows the final symlink, which is what makes a link back to an
    /// ancestor the same directory we have already entered.
    private func directoryIdentity(_ path: String) -> InodeKey? {
        var st = stat()
        guard stat(path, &st) == 0, let fsid = fsidOf(path: path) else { return nil }
        return InodeKey(fsid: fsid, fileID: st.st_ino)
    }
}

/// The first name that still has bytes keeps them. A name already zeroed does
/// not count as the charged copy, so running this again after a widen cannot
/// drop the only copy.
func chargeHardlinks(_ node: inout Node, charged: inout Set<InodeKey>) {
    if !node.isDirectory {
        if let inode = node.inode {
            if charged.contains(inode) {
                node.ownBytes = 0
            } else if node.ownBytes > 0 {
                charged.insert(inode)
            }
        }
        return
    }
    for index in node.children.indices {
        chargeHardlinks(&node.children[index], charged: &charged)
    }
}
