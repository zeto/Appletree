import Darwin
import Foundation

public struct Mount: Sendable, Equatable {
    public var source: String
    public var point: String
    public var fstype: String
    public var fsid: UInt64

    public init(source: String, point: String, fstype: String, fsid: UInt64) {
        self.source = source
        self.point = point
        self.fstype = fstype
        self.fsid = fsid
    }
}

public enum VolumePolicy: String, Sendable, Equatable {
    /// Stay on the volume that contains the scan root.
    case oneVolume
    /// The startup APFS volume group: the sealed system volume plus its Data volume.
    case startupDisk
    case unrestricted
}

public struct VolumeBoundary: Sendable, Equatable {
    public var allowedFSIDs: Set<UInt64>
    public var blockedPaths: [String]

    public init(allowedFSIDs: Set<UInt64> = [], blockedPaths: [String] = []) {
        self.allowedFSIDs = allowedFSIDs
        self.blockedPaths = blockedPaths
    }
}

/// Paths that would count the Data volume a second time, or that are other
/// volumes glued onto `/System/Volumes`.
public let startupDiskDenylist = [
    "/System/Volumes/Data",
    "/System/Volumes/Preboot",
    "/System/Volumes/VM",
    "/System/Volumes/Update",
    "/System/Volumes/xarts",
    "/System/Volumes/iSCPreboot",
    "/System/Volumes/Hardware",
]

public func makeBoundary(
    mounts: [Mount],
    root: String,
    rootFSID: UInt64,
    policy: VolumePolicy
) -> VolumeBoundary {
    let root = normalize(path: root)
    switch policy {
    case .unrestricted:
        return VolumeBoundary()
    case .oneVolume:
        let blocked = mounts.compactMap { mount -> String? in
            let point = normalize(path: mount.point)
            guard point != root, isWithin(point, root), mount.fsid != rootFSID else { return nil }
            return point
        }
        return VolumeBoundary(allowedFSIDs: [rootFSID], blockedPaths: blocked)
    case .startupDisk:
        let dataFSID = mounts.first { normalize(path: $0.point) == "/System/Volumes/Data" }?.fsid
        var allowed: Set<UInt64> = [rootFSID]
        if let dataFSID { allowed.insert(dataFSID) }
        var blocked = Set(startupDiskDenylist)
        for mount in mounts {
            let point = normalize(path: mount.point)
            guard point != root, isWithin(point, root) else { continue }
            if !allowed.contains(mount.fsid) {
                blocked.insert(point)
            }
        }
        return VolumeBoundary(allowedFSIDs: allowed, blockedPaths: Array(blocked).sorted())
    }
}

public func shouldEnter(path: String, fsid: UInt64, boundary: VolumeBoundary) -> Bool {
    let path = normalize(path: path)
    for blocked in boundary.blockedPaths {
        if path == blocked || path.hasPrefix(blocked + "/") { return false }
    }
    if boundary.allowedFSIDs.isEmpty || fsid == 0 { return true }
    return boundary.allowedFSIDs.contains(fsid)
}

public struct SpaceInfo: Sendable, Equatable {
    public var total: UInt64
    public var free: UInt64
    public var available: UInt64
    /// Capacity available if macOS purges caches and local snapshots. Nil when unreadable.
    public var important: UInt64?

    public init(total: UInt64, free: UInt64, available: UInt64, important: UInt64? = nil) {
        self.total = total
        self.free = free
        self.available = available
        self.important = important
    }

    public var used: UInt64 { total > free ? total - free : 0 }

    public var usedFraction: Double {
        if total == 0 { return 0 }
        return Double(used) / Double(total)
    }

    /// Space macOS says it can reclaim without the user deleting a file.
    public var purgeable: UInt64 {
        guard let important, important > available else { return 0 }
        return important - available
    }

    public func afterRemoving(_ bytes: UInt64) -> SpaceInfo {
        SpaceInfo(
            total: total,
            free: min(total, free.addingReportingOverflow(bytes).partialValue),
            available: min(total, available.addingReportingOverflow(bytes).partialValue),
            important: important.map { min(total, $0.addingReportingOverflow(bytes).partialValue) }
        )
    }
}

public func spaceInfo(path: String) -> SpaceInfo? {
    var st = statfs()
    guard statfs(path, &st) == 0 else { return nil }
    let block = st.f_bsize == 0 ? 512 : UInt64(st.f_bsize)
    let info = SpaceInfo(
        total: st.f_blocks * block,
        free: st.f_bfree * block,
        available: st.f_bavail * block
    )
    let url = URL(fileURLWithPath: path)
    let important = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage
        .map { UInt64(max(0, $0)) }
    return SpaceInfo(total: info.total, free: info.free, available: info.available, important: important)
}

public func fsidOf(path: String) -> UInt64? {
    var st = statfs()
    guard statfs(path, &st) == 0 else { return nil }
    return withUnsafeBytes(of: st.f_fsid) { raw in
        raw.baseAddress?.loadUnaligned(as: UInt64.self)
    }
}

public func currentMounts() -> [Mount] {
    var buffer: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&buffer, MNT_NOWAIT)
    guard count > 0, let buffer else { return [] }
    var mounts: [Mount] = []
    mounts.reserveCapacity(Int(count))
    for index in 0..<Int(count) {
        let entry = buffer[index]
        mounts.append(Mount(
            source: decodeCString(entry.f_mntfromname),
            point: decodeCString(entry.f_mntonname),
            fstype: decodeCString(entry.f_fstypename),
            fsid: withUnsafeBytes(of: entry.f_fsid) { $0.baseAddress?.loadUnaligned(as: UInt64.self) ?? 0 }
        ))
    }
    return mounts
}

public func liveBoundary(root: String, policy: VolumePolicy) -> VolumeBoundary {
    let root = normalize(path: root)
    let fsid = fsidOf(path: root) ?? 0
    return makeBoundary(mounts: currentMounts(), root: root, rootFSID: fsid, policy: policy)
}

/// A path is a mount point when the mount table lists it. `st_dev` is shared by
/// the whole APFS volume group, so it cannot tell `/` from `/System/Volumes/Data`.
public func mountPoints() -> Set<String> {
    Set(currentMounts().map { normalize(path: $0.point) })
}

private func decodeCString<T>(_ value: T) -> String {
    withUnsafePointer(to: value) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
}
