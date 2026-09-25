import Darwin
import Foundation

public struct Target: Sendable, Equatable, Identifiable {
    public var path: String
    public var bytes: UInt64
    public var hidden: Bool

    public var id: String { path }

    public init(path: String, bytes: UInt64, hidden: Bool = false) {
        self.path = path
        self.bytes = bytes
        self.hidden = hidden
    }
}

public enum RemovalMode: String, Sendable, Equatable {
    case trash
    case permanent
}

public struct Blocked: Sendable, Equatable, Identifiable {
    public var path: String
    public var reason: String
    public var id: String { path }

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct RemovalPlan: Sendable, Equatable {
    public var targets: [Target]
    public var absorbed: [Target]
    public var blocked: [Blocked]

    public init(targets: [Target] = [], absorbed: [Target] = [], blocked: [Blocked] = []) {
        self.targets = targets
        self.absorbed = absorbed
        self.blocked = blocked
    }

    public var bytes: UInt64 { targets.reduce(0) { $0 + $1.bytes } }
}

public struct PathInfo: Sendable, Equatable {
    public var isMountPoint: Bool
    public var owner: UInt32?
    public var flags: UInt32
    public var isSymlink: Bool

    public init(isMountPoint: Bool = false, owner: UInt32? = nil, flags: UInt32 = 0, isSymlink: Bool = false) {
        self.isMountPoint = isMountPoint
        self.owner = owner
        self.flags = flags
        self.isSymlink = isSymlink
    }
}

public struct RemovalContext: Sendable {
    public var root: String
    public var home: String?
    public var user: UInt32
    public var lookup: @Sendable (String) -> PathInfo

    public init(root: String, home: String?, user: UInt32, lookup: @escaping @Sendable (String) -> PathInfo) {
        self.root = root
        self.home = home
        self.user = user
        self.lookup = lookup
    }
}

public func plan(targets: [Target], context: RemovalContext) -> RemovalPlan {
    let root = normalize(path: context.root)
    let home = context.home.map { normalize(path: $0) }
    var result = RemovalPlan()
    var accepted: [Target] = []
    let ordered = targets
        .map { Target(path: normalize(path: $0.path), bytes: $0.bytes, hidden: $0.hidden) }
        .sorted { $0.path.count < $1.path.count }
    for target in ordered {
        if let reason = refuse(target.path, root: root, home: home, user: context.user, lookup: context.lookup) {
            result.blocked.append(Blocked(path: target.path, reason: reason))
            continue
        }
        if accepted.contains(where: { isWithin(target.path, $0.path) && target.path != $0.path }) {
            result.absorbed.append(target)
        } else {
            accepted.append(target)
        }
    }
    result.targets = accepted
    return result
}

public func liveContext(root: String) -> RemovalContext {
    let mounts = mountPoints()
    let user = getuid()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return RemovalContext(root: root, home: home, user: user) { path in
        var info = PathInfo(isMountPoint: mounts.contains(normalize(path: path)))
        var st = stat()
        if lstat(path, &st) == 0 {
            info.owner = st.st_uid
            info.flags = st.st_flags
            info.isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
        }
        return info
    }
}

public func plan(targets: [Target], root: String) -> RemovalPlan {
    plan(targets: targets, context: liveContext(root: root))
}

private let systemTrees = [
    "/System",
    "/bin",
    "/sbin",
    "/usr",
    "/Library",
    "/private",
    "/opt/homebrew",
    "/opt/local",
    "/dev",
    "/etc",
    "/var",
]

func refuse(
    _ path: String,
    root: String,
    home: String?,
    user: UInt32,
    lookup: (String) -> PathInfo
) -> String? {
    let path = normalize(path: path)
    if path == "/" {
        return "the filesystem root cannot be removed"
    }
    if path == root {
        return "the scanned root cannot be removed"
    }
    if let home, path == home {
        return "the home directory cannot be removed"
    }
    if !isWithin(path, root) {
        return "outside the scanned root"
    }
    if let home, isWithin(path, home) {
        if lookup(path).isMountPoint {
            return "a mount point: removing it would cross onto another filesystem"
        }
        return nil
    }
    if path == "/Users" {
        return "the users directory cannot be removed"
    }
    if let other = otherUserHome(path, userHome: home) {
        return "another user's home under \(other)"
    }
    if let system = systemTrees.first(where: { isWithin(path, $0) }) {
        return "part of the system under \(system)"
    }
    if path == "/Applications" {
        return "the Applications folder cannot be removed"
    }
    if let app = applicationBundle(path), isWithin(path, "/Applications") {
        let info = lookup(app)
        let restricted = info.flags & UInt32(bitPattern: SF_RESTRICTED) != 0
        if info.owner == nil || info.owner == 0 || restricted {
            return "a system app under /Applications"
        }
        if info.owner != user {
            return "an application owned by another user"
        }
    }
    if lookup(path).isMountPoint {
        return "a mount point: removing it would cross onto another filesystem"
    }
    return nil
}

private func otherUserHome(_ path: String, userHome: String?) -> String? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 2, parts[0] == "Users" else { return nil }
    let homeName = String(parts[1])
    if let userHome {
        let own = URL(fileURLWithPath: userHome).lastPathComponent
        if homeName == own { return nil }
    }
    return "/Users/\(homeName)"
}

private func applicationBundle(_ path: String) -> String? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    var built = ""
    for part in parts {
        built = built == "" ? "/" + part : built + "/" + part
        if part.hasSuffix(".app") { return built }
    }
    return nil
}

public enum RemovalEvent: Sendable, Equatable {
    case start(total: Int)
    case item(path: String, bytes: UInt64, error: String?)
    case done(removed: Int, bytes: UInt64, failed: Int)
}

public func removePermanently(_ path: String) throws {
    var st = stat()
    if lstat(path, &st) != 0 {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
    }
    if (st.st_mode & S_IFMT) == S_IFLNK {
        if unlink(path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
        return
    }
    try FileManager.default.removeItem(atPath: path)
}

@discardableResult
public func moveToTrash(_ path: String) throws -> URL {
    var result: NSURL?
    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
    return (result as URL?) ?? URL(fileURLWithPath: path)
}

public func perform(
    _ removalPlan: RemovalPlan,
    mode: RemovalMode,
    isCancelled: @Sendable () -> Bool = { false },
    onEvent: @Sendable (RemovalEvent) -> Void = { _ in }
) {
    onEvent(.start(total: removalPlan.targets.count))
    var removed = 0
    var bytes: UInt64 = 0
    var failed = 0
    for target in removalPlan.targets {
        if isCancelled() { break }
        do {
            switch mode {
            case .permanent:
                try removePermanently(target.path)
            case .trash:
                try moveToTrash(target.path)
            }
            removed += 1
            bytes += target.bytes
            onEvent(.item(path: target.path, bytes: target.bytes, error: nil))
        } catch {
            failed += 1
            onEvent(.item(path: target.path, bytes: target.bytes, error: error.localizedDescription))
        }
    }
    onEvent(.done(removed: removed, bytes: bytes, failed: failed))
}
