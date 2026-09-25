import XCTest
@testable import AppletreeCore

final class TreeTests: XCTestCase {
    func testAggregateDerivesTotalsAndOrdersChildren() {
        var root = Node.directory("root")
        var nested = Node.directory("child")
        nested.children = [Node.entry("deep", kind: .file, bytes: 7)]
        root.children = [nested, Node.entry("direct", kind: .file, bytes: 5), Node.entry("small", kind: .file, bytes: 9)]
        aggregate(&root, metric: .bytes)
        XCTAssertEqual(root.ownBytes, 14)
        XCTAssertEqual(root.bytes, 21)
        XCTAssertEqual(root.files, 3)
        XCTAssertEqual(root.ownFiles, 2)
        XCTAssertEqual(root.dirs, 2)
        XCTAssertEqual(root.child(named: "child")?.ownBytes, 7)
        XCTAssertEqual(root.children.map(\.name), ["small", "child", "direct"])
    }

    func testAggregateRanksByFileCount() {
        var root = Node.directory("root")
        var many = Node.directory("many")
        many.children = (0..<5).map { Node.entry("f\($0)", kind: .file, bytes: 1) }
        root.children = [many, Node.entry("huge", kind: .file, bytes: 10_000)]
        aggregate(&root, metric: .bytes)
        XCTAssertEqual(root.children[0].name, "huge")
        aggregate(&root, metric: .files)
        XCTAssertEqual(root.children[0].name, "many")
        XCTAssertEqual(root.children[0].files, 5)
    }

    func testPathAndNormalize() {
        var root = Node.directory("root")
        var nested = Node.directory("child")
        nested.children = [Node.entry("deep", kind: .file, bytes: 1)]
        root.children = [nested]
        XCTAssertEqual(path(ofRoot: "/home/tobi", node: root, crumbs: [0, 0]), "/home/tobi/child/deep")
        XCTAssertEqual(normalize(path: "/Users/jag/../jag"), "/Users/jag")
        XCTAssertEqual(normalize(path: "/"), "/")
        XCTAssertEqual(normalize(path: "/.."), "/")
        XCTAssertTrue(isWithin("/Users/jag/src", "/Users/jag"))
        XCTAssertFalse(isWithin("/Users/ja", "/Users/j"))
        XCTAssertFalse(isWithin("/Users/jag2", "/Users/jag"))
    }

    func testHardlinkChargeKeepsTheFirstCopyWithBytes() {
        var root = Node.directory("root")
        let key = InodeKey(fsid: 1, fileID: 9)
        var first = Node.entry("a", kind: .file, bytes: 50)
        var second = Node.entry("b", kind: .file, bytes: 0)
        var third = Node.entry("c", kind: .file, bytes: 50)
        first.inode = key
        second.inode = key
        third.inode = key
        root.children = [second, third, first]
        var charged = Set<InodeKey>()
        chargeHardlinks(&root, charged: &charged)
        aggregate(&root, metric: .bytes)
        XCTAssertEqual(root.bytes, 50)
        XCTAssertEqual(root.files, 3)
    }
}

final class SizeTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(humanBytes(0), "0 B")
        XCTAssertEqual(humanBytes(12), "12 B")
        XCTAssertEqual(humanBytes(1024), "1.0 KiB")
        XCTAssertEqual(humanBytes(1536), "1.5 KiB")
        XCTAssertEqual(humanBytes(512 * 1024 * 1024), "512 MiB")
        XCTAssertEqual(humanBytesShort(1536), "1.5KiB")
    }

    func testShare() {
        XCTAssertEqual(share(part: 5, total: 0), 0)
        XCTAssertEqual(share(part: 1, total: 4), 25)
    }
}

final class LayoutTests: XCTestCase {
    func testSquarifyFillsTheArea() {
        let area = Rect(x: 0, y: 0, w: 800, h: 500)
        let rects = squarify([40, 30, 20, 5, 3, 2], area: area)
        let covered = rects.reduce(0) { $0 + $1.area }
        XCTAssertEqual(covered, area.area, accuracy: 1)
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.x, -0.01)
            XCTAssertGreaterThanOrEqual(rect.y, -0.01)
            XCTAssertLessThanOrEqual(rect.right, area.right + 0.01)
            XCTAssertLessThanOrEqual(rect.bottom, area.bottom + 0.01)
        }
    }

    func testSquarifyAspect() {
        let rects = squarify([6, 6, 4, 3, 2, 2, 1], area: Rect(x: 0, y: 0, w: 600, h: 400))
        for rect in rects {
            let ratio = max(rect.w / rect.h, rect.h / rect.w)
            XCTAssertLessThanOrEqual(ratio, 4)
        }
    }

    func testLayoutNestsAndHitsTheHeader() {
        let root = directory("root", [
            directory("big", [Node.entry("inside", kind: .file, bytes: 100), Node.entry("also", kind: .file, bytes: 50)]),
            Node.entry("small", kind: .file, bytes: 10),
        ])
        let tiles = layout(root: root, rootCrumbs: [], area: Rect(x: 0, y: 0, w: 800, h: 500), metric: .bytes)
        XCTAssertEqual(tiles.map(\.crumbs), [[0], [0, 0], [0, 1], [1]])
        let header = try! XCTUnwrap(tiles[0].header)
        let hitTile = try! XCTUnwrap(hit(tiles, x: header.x + header.w / 2, y: header.y + header.h / 2))
        XCTAssertEqual(hitTile.crumbs, [0])
        let child = tiles[1]
        let centre = hit(tiles, x: child.rect.x + child.rect.w / 2, y: child.rect.y + child.rect.h / 2)
        XCTAssertEqual(centre?.crumbs, [0, 0])
    }

    func testCrumbsStayAbsolute() {
        let node = directory("inner", [Node.entry("a", kind: .file, bytes: 10), Node.entry("b", kind: .file, bytes: 5)])
        let tiles = layout(root: node, rootCrumbs: [3, 1], area: Rect(x: 0, y: 0, w: 800, h: 500), metric: .bytes)
        XCTAssertFalse(tiles.isEmpty)
        for tile in tiles {
            XCTAssertTrue(tile.crumbs.starts(with: [3, 1]))
        }
    }

    func testTailMerges() {
        let children = (0..<10).map { Node.entry("f\($0)", kind: .file, bytes: UInt64(10 - $0)) }
        let root = directory("root", children)
        var options = LayoutOptions()
        options.maxChildren = 4
        let tiles = layout(root: root, rootCrumbs: [], area: Rect(x: 0, y: 0, w: 800, h: 500), metric: .bytes, options: options)
        let others = tiles.filter {
            if case .others(_, let count) = $0.kind { return count == 6 }
            return false
        }
        XCTAssertEqual(others.count, 1)
    }
}

final class FilterAndClassTests: XCTestCase {
    func testFilterKeepsMatchesWhole() {
        let root = directory("root", [
            directory("src", [directory("App", [Node.entry("main.rs", kind: .file, bytes: 10)]), Node.entry("notes", kind: .file, bytes: 5)]),
            directory("apps", [Node.entry("x", kind: .file, bytes: 100), directory("apple", [Node.entry("y", kind: .file, bytes: 7)])]),
            Node.entry("readme", kind: .file, bytes: 1),
        ])
        let found = try! XCTUnwrap(filter(node: root, needle: "APP"))
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.bytes, 117)
        XCTAssertEqual(found.keep(at: crumbs(root, ["apps"])), .whole)
        XCTAssertNil(found.keep(at: crumbs(root, ["src", "notes"])))
        XCTAssertNil(filter(node: root, needle: "  "))
    }

    func testClassifyNamesAndCargoTarget() {
        var home = directory("tobi", [
            directory("src", [directory("tries", [directory("dated", [Node.entry("a", kind: .file, bytes: 1)])])]),
            directory(".cache", [directory("store", [Node.entry("b", kind: .file, bytes: 1)])]),
            directory("world", [directory(".git", [directory("objects", [Node.entry("c", kind: .file, bytes: 9)])]), Node.entry("README", kind: .file, bytes: 1)]),
            directory("rust-thing", [Node.entry("Cargo.toml", kind: .file, bytes: 1), directory("target", [Node.entry("d", kind: .file, bytes: 5)])]),
            directory("js-thing", [directory("target", [Node.entry("e", kind: .file, bytes: 5)])]),
            directory("swift-thing", [Node.entry("Package.swift", kind: .file, bytes: 1), directory(".build", [Node.entry("f", kind: .file, bytes: 5)])]),
            directory("DerivedData", [Node.entry("g", kind: .file, bytes: 8)]),
            directory("mystery", [Node.entry("i", kind: .file, bytes: 1)]),
        ])
        aggregate(&home, metric: .bytes)
        classify(&home)
        XCTAssertEqual(home.child(named: "src")?.category, .code)
        XCTAssertEqual(home.child(named: "src")?.child(named: "tries")?.category, .agentScratch)
        XCTAssertEqual(home.child(named: "src")?.child(named: "tries")?.child(named: "dated")?.category, .agentScratch)
        XCTAssertEqual(home.child(named: ".cache")?.reclaim, .regenerable)
        XCTAssertEqual(home.child(named: ".cache")?.child(named: "store")?.reclaim, .regenerable)
        XCTAssertEqual(home.child(named: "world")?.category, .git)
        XCTAssertEqual(home.child(named: "rust-thing")?.child(named: "target")?.reclaim, .buildOutput)
        XCTAssertNil(home.child(named: "js-thing")?.child(named: "target")?.reclaim)
        XCTAssertEqual(home.child(named: "swift-thing")?.child(named: ".build")?.reclaim, .buildOutput)
        XCTAssertEqual(home.child(named: "DerivedData")?.reclaim, .buildOutput)
        XCTAssertEqual(home.child(named: "mystery")?.category, .other)
    }
}

final class VolumeAndRemovalTests: XCTestCase {
    func testStartupDiskBoundary() {
        let mounts = [
            Mount(source: "disk3s1", point: "/", fstype: "apfs", fsid: 1),
            Mount(source: "disk3s5", point: "/System/Volumes/Data", fstype: "apfs", fsid: 2),
            Mount(source: "disk3s2", point: "/System/Volumes/Preboot", fstype: "apfs", fsid: 3),
            Mount(source: "disk4", point: "/Volumes/Extra", fstype: "apfs", fsid: 4),
        ]
        let boundary = makeBoundary(mounts: mounts, root: "/", rootFSID: 1, policy: .startupDisk)
        XCTAssertTrue(boundary.allowedFSIDs.contains(1))
        XCTAssertTrue(boundary.allowedFSIDs.contains(2))
        XCTAssertFalse(shouldEnter(path: "/System/Volumes/Data", fsid: 2, boundary: boundary))
        XCTAssertFalse(shouldEnter(path: "/System/Volumes/Preboot", fsid: 3, boundary: boundary))
        XCTAssertFalse(shouldEnter(path: "/Volumes/Extra", fsid: 4, boundary: boundary))
        XCTAssertTrue(shouldEnter(path: "/Users/jag", fsid: 2, boundary: boundary))
        XCTAssertTrue(shouldEnter(path: "/usr", fsid: 1, boundary: boundary))
    }

    func testProjectionSaturates() {
        let space = SpaceInfo(total: 1000, free: 100, available: 100)
        XCTAssertEqual(space.afterRemoving(50).available, 150)
        XCTAssertEqual(space.afterRemoving(10_000).available, 1000)
        XCTAssertEqual(SpaceInfo(total: 0, free: 0, available: 0).usedFraction, 0)
    }

    func testRemovalGuards() {
        let context = RemovalContext(root: "/Users/tester", home: "/Users/tester", user: 501) { path in
            PathInfo(isMountPoint: path == "/Users/tester/mnt")
        }
        func reason(_ path: String) -> String? {
            plan(targets: [Target(path: path, bytes: 1)], context: RemovalContext(
                root: "/",
                home: "/Users/tester",
                user: 501,
                lookup: context.lookup
            )).blocked.first?.reason
        }
        XCTAssertEqual(reason("/"), "the filesystem root cannot be removed")
        XCTAssertEqual(reason("/Users/tester"), "the home directory cannot be removed")
        XCTAssertNotNil(reason("/System/Library"))
        XCTAssertNotNil(reason("/usr/local/bin"))
        XCTAssertEqual(
            plan(targets: [Target(path: "/Users/tester", bytes: 1)], context: context).blocked.first?.reason,
            "the scanned root cannot be removed"
        )
        let mount = plan(targets: [Target(path: "/Users/tester/mnt", bytes: 1)], context: context)
        XCTAssertEqual(mount.blocked.first?.reason, "a mount point: removing it would cross onto another filesystem")
        let outside = RemovalContext(root: "/Users/tester/project", home: "/Users/tester", user: 501) { _ in PathInfo() }
        XCTAssertEqual(
            plan(targets: [Target(path: "/Users/tester/other", bytes: 1)], context: outside).blocked.first?.reason,
            "outside the scanned root"
        )
        let app = RemovalContext(root: "/", home: "/Users/tester", user: 501) { path in
            path == "/Applications/Mine.app" ? PathInfo(owner: 501) : PathInfo(owner: 0, flags: 0)
        }
        XCTAssertTrue(plan(targets: [Target(path: "/Applications/Mine.app", bytes: 1)], context: app).blocked.isEmpty)
        XCTAssertFalse(plan(targets: [Target(path: "/Applications/System.app", bytes: 1)], context: app).blocked.isEmpty)
        let nested = plan(targets: [
            Target(path: "/Users/tester/a", bytes: 10),
            Target(path: "/Users/tester/a/b", bytes: 4),
        ], context: context)
        XCTAssertEqual(nested.targets.map(\.path), ["/Users/tester/a"])
        XCTAssertEqual(nested.absorbed.map(\.path), ["/Users/tester/a/b"])
    }

    func testPermanentDeleteLeavesTheSibling() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("keep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drop"), withIntermediateDirectories: true)
        let kept = root.appendingPathComponent("keep/safe.txt")
        try Data("safe".utf8).write(to: kept)
        try Data("gone".utf8).write(to: root.appendingPathComponent("drop/gone.txt"))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("appletree-outside-\(UUID().uuidString)")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        try removePermanently(root.appendingPathComponent("drop").path)
        try removePermanently(root.appendingPathComponent("link").path)
        XCTAssertEqual(try Data(contentsOf: kept), Data("safe".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("drop").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("link").path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }
}

final class ScanTests: XCTestCase {
    func testTotalsHiddenLinksAndHardlinks() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a/one.bin", 1000)
        try write(root, "a/nested/two.bin", 2000)
        try write(root, "b/three.bin", 500)
        try write(root, ".cache/blob.bin", 900)
        try write(root, "visible.bin", 100)
        let original = try write(root, "original.bin", 4096)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("link.bin"))
        let outside = try makeTemp()
        defer { try? FileManager.default.removeItem(at: outside) }
        try write(outside, "elsewhere.bin", 5000)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let tree = try scan(root: root, options: ScanOptions(apparentSize: true))
        XCTAssertEqual(tree.child(named: "a")?.bytes, 3000)
        XCTAssertEqual(tree.child(named: "a")?.child(named: "nested")?.bytes, 2000)
        XCTAssertEqual(tree.child(named: ".cache")?.bytes, 900)
        XCTAssertEqual(tree.child(named: "original.bin")?.bytes, 4096)
        let link = try XCTUnwrap(tree.child(named: "link"))
        XCTAssertEqual(link.kind, .symlink)
        XCTAssertLessThan(link.bytes, 100)
        let hardlinkBytes = (tree.child(named: "original.bin")?.bytes ?? 0) + (tree.child(named: "link.bin")?.bytes ?? 0)
        XCTAssertEqual(hardlinkBytes, 4096)
        XCTAssertEqual(tree.files, 7)

        let withoutHidden = try scan(root: root, options: ScanOptions(apparentSize: true, includeHidden: false))
        XCTAssertNil(withoutHidden.child(named: ".cache"))
    }

    func testFollowedSymlinkLoopTerminates() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "sub/leaf.bin", 42)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sub/loop"), withDestinationURL: root)
        let tree = try scan(root: root, options: ScanOptions(apparentSize: true, followLinks: true))
        XCTAssertEqual(tree.bytes, 42)
    }

    func testMaxDepthStops() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "here.bin", 10)
        try write(root, "a/there.bin", 20)
        try write(root, "a/b/far.bin", 30)
        let tree = try scan(root: root, options: ScanOptions(apparentSize: true, maxDepth: 1))
        XCTAssertEqual(tree.ownBytes, 10)
        let a = try XCTUnwrap(tree.child(named: "a"))
        XCTAssertEqual(a.bytes, 20)
        XCTAssertTrue(a.children.allSatisfy { !$0.isDirectory })
    }

    func testUnreadableDirectoryIsRecorded() throws {
        let root = try makeTemp()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("locked").path)
            try? FileManager.default.removeItem(at: root)
        }
        try write(root, "readable.bin", 11)
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: locked.appendingPathComponent("hidden.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        guard (try? FileManager.default.contentsOfDirectory(atPath: locked.path)) == nil else { return }
        let tree = try scan(root: root, options: ScanOptions(apparentSize: true))
        XCTAssertEqual(tree.child(named: "readable.bin")?.bytes, 11)
        XCTAssertTrue(tree.child(named: "locked")?.readError ?? false)
        XCTAssertEqual(tree.bytes, 11)
    }

    func testLiveVolumeNumbers() {
        let space = spaceInfo(path: NSTemporaryDirectory())
        let info = try! XCTUnwrap(space)
        XCTAssertGreaterThan(info.total, 0)
        XCTAssertLessThanOrEqual(info.free, info.total)
        XCTAssertLessThanOrEqual(info.available, info.free)
    }
}

private func directory(_ name: String, _ children: [Node]) -> Node {
    var node = Node.directory(name)
    node.children = children
    aggregate(&node, metric: .bytes)
    return node
}

private func crumbs(_ root: Node, _ names: [String]) -> [Int] {
    var node = root
    return names.map { name in
        let index = node.children.firstIndex { $0.name == name }!
        node = node.children[index]
        return index
    }
}

private func makeTemp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("appletree-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func write(_ root: URL, _ relative: String, _ bytes: Int) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x78, count: bytes).write(to: url)
    return url
}
