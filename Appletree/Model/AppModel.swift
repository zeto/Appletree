import AppKit
import AppletreeCore
import Observation
import os
import SwiftUI

struct ViewTransform: Equatable {
    var scale: CGFloat = 1
    var origin: CGPoint = .zero

    func screen(_ rect: Rect) -> CGRect {
        CGRect(
            x: (CGFloat(rect.x) - origin.x) * scale,
            y: (CGFloat(rect.y) - origin.y) * scale,
            width: CGFloat(rect.w) * scale,
            height: CGFloat(rect.h) * scale
        )
    }

    func base(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x / max(scale, 0.01), y: origin.y + point.y / max(scale, 0.01))
    }
}

struct CrumbItem: Identifiable, Equatable {
    var id: String
    var title: String
    var path: String
    var crumbs: [Int]?
    var dim: Bool
}

enum AppScreen: Equatable {
    case explore
    case review
}

@MainActor
@Observable
final class AppModel {
    var rootPath: String
    var options: ScanOptions
    var tree: Node?
    var generation = 0
    var progress = ScanSnapshot()
    var scanning = false
    var scanError: String?
    var viewCrumbs: [Int] = []
    var selection: [Int] = []
    var hover: [Int]?
    var keyboardOwnsSelection = false
    var colorMode: ColorMode = .category
    var depth = 3
    var filterText = ""
    var filterCommitted = false
    var marks = MarkSet()
    var space: SpaceInfo?
    var findings: [Candidate] = []
    var screen: AppScreen = .explore
    var showHelp = false
    var showSelection = true
    var transform = ViewTransform()
    var status: String?
    var confirmingPermanent = false
    var removing = false
    var interfaceScale: CGFloat = 1
    var panelWidth: CGFloat = 23 * 16
    var canvasSize: CGSize = .zero
    var motion: MosaicMotion?
    /// The map as it looked the instant a zoom began. Dropped when the zoom ends.
    var backdrop: MosaicBackdrop?

    @ObservationIgnored private var layoutCache = LayoutCache()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var activeScan: ScanHandle?
    @ObservationIgnored private var scanToken = UUID()
    @ObservationIgnored private var known: Known?
    @ObservationIgnored private var pendingSummary: String?
    /// When a scroll gesture lands back on the original framing, its tail should not also leave the folder.
    @ObservationIgnored private var settledZoomAt: Date?

    init() {
        let parsed = Launch.parse()
        rootPath = parsed.root
        options = parsed.options
        depth = parsed.depth
        if Launch.scansOnLaunch {
            scanning = true
        }
    }

    /// Nothing has been chosen yet, so the window offers the scan actions.
    var awaitsScan: Bool { tree == nil && !scanning && !Launch.demo }

    var rem: CGFloat { 16 * interfaceScale }

    var viewNode: Node? { tree?.resolve(viewCrumbs) }

    var selectedNode: Node? { tree?.resolve(selection) }

    var activeCrumbs: [Int]? {
        if keyboardOwnsSelection { return selection.isEmpty ? nil : selection }
        return hover ?? (selection.isEmpty ? nil : selection)
    }

    var liveFilter: Matches? {
        guard let node = viewNode, !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return filter(node: node, base: viewCrumbs, needle: filterText)
    }

    var removalPlan: RemovalPlan {
        plan(targets: marks.targets(), root: rootPath)
    }

    var permanentMessage: String {
        let removal = removalPlan
        let names = removal.targets.prefix(6).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        let extra = removal.targets.count - names.count
        let list = names.joined(separator: ", ") + (extra > 0 ? " and \(extra) more" : "")
        return "\(list) — \(humanBytes(removal.bytes)). This cannot be undone."
    }

    func start() {
        if Launch.demo {
            loadDemo()
            return
        }
        guard Launch.scansOnLaunch, !rootPath.isEmpty else { return }
        scan(path: rootPath, policy: options.volumePolicy, known: nil)
    }

    /// A small made-up tree so the window can be opened without scanning a disk.
    func loadDemo() {
        var root = Node.directory("Demo")
        let samples: [(String, UInt64)] = [
            ("Movies", 900),
            ("src", 380),
            ("Caches", 240),
            ("Documents", 120),
            ("Music", 70),
        ]
        root.children = samples.map { name, megabytes in
            var directory = Node.directory(name)
            directory.children = [Node.entry("data", kind: .file, bytes: megabytes * 1_000_000)]
            return directory
        }
        aggregate(&root, metric: .bytes)
        classify(&root)
        tree = root
        rootPath = "/Demo"
        scanning = false
        generation += 1
        viewCrumbs = []
        selection = []
        space = SpaceInfo(total: 2_000_000_000_000, free: 800_000_000_000, available: 700_000_000_000)
    }

    private var didPickCorner = false

    func selectBottomLeft(in size: CGSize) {
        guard Launch.demo, !didPickCorner, size.width > 1, size.height > 1, tree != nil else { return }
        let tiles = self.tiles(in: size)
        let x = 8.0
        let y = Double(size.height - 8)
        let tile = tiles.first { $0.depth == 0 && $0.rect.contains(x, y) }
            ?? tiles.filter { $0.depth == 0 }.min { $0.rect.x < $1.rect.x }
        guard let tile else { return }
        selection = tile.crumbs
        keyboardOwnsSelection = true
        didPickCorner = true
    }

    func scanHome() {
        scan(path: FileManager.default.homeDirectoryForCurrentUser.path, policy: .oneVolume, known: nil)
    }

    func scanStartupDisk() {
        scan(path: "/", policy: .startupDisk, known: isWithin(rootPath, "/") ? known : nil)
    }

    func rescan() {
        guard !rootPath.isEmpty else { return }
        scan(path: rootPath, policy: options.volumePolicy, known: nil)
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.scan(path: url.path, policy: .oneVolume, known: nil)
            }
        }
    }

    func scanDropped(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        scan(path: url.path, policy: .oneVolume, known: nil)
    }

    func scan(path: String, policy: VolumePolicy, known: Known?) {
        activeScan?.cancel()
        scanTask?.cancel()
        let path = normalize(path: path)
        let token = UUID()
        scanToken = token
        rootPath = path
        options.volumePolicy = policy
        scanning = true
        scanError = nil
        status = nil
        var scanOptions = options
        scanOptions.volumePolicy = policy
        self.options = scanOptions
        scanTask = Task { [scanOptions] in
            let handle: ScanHandle
            do {
                handle = try ScanHandle.start(root: URL(fileURLWithPath: path), options: scanOptions, known: known)
            } catch {
                guard scanToken == token else { return }
                scanning = false
                scanError = error.localizedDescription
                return
            }
            activeScan = handle
            let result = Task.detached { try handle.wait() }
            while !Task.isCancelled && scanToken == token && !handle.isFinished {
                progress = handle.snapshot()
                try? await Task.sleep(for: .milliseconds(120))
            }
            if Task.isCancelled || scanToken != token {
                handle.cancel()
                result.cancel()
                return
            }
            progress = handle.snapshot()
            do {
                let node = try await result.value
                guard scanToken == token else { return }
                apply(node, path: path, options: scanOptions)
            } catch {
                guard scanToken == token else { return }
                scanning = false
                if let scanError = error as? ScanError, scanError == .cancelled { return }
                self.scanError = error.localizedDescription
            }
        }
    }

    private func apply(_ node: Node, path: String, options: ScanOptions) {
        tree = node
        generation += 1
        scanning = false
        progress.finished = true
        rootPath = path
        known = Known(path: path, options: options, tree: node)
        viewCrumbs = []
        selection = node.largestChild.map { [$0] } ?? []
        hover = nil
        transform = ViewTransform()
        filterCommitted = false
        marks = marks.refreshed(rootPath: path, tree: node)
        space = spaceInfo(path: path)
        findings = worthALook(root: node, now: Int64(Date().timeIntervalSince1970), limit: 8)
        layoutCache.clear()
        beginMotion(.intro, focus: .zero, duration: 0.72)
        if let summary = pendingSummary {
            status = summary
            pendingSummary = nil
        }
    }

    func tiles(in size: CGSize) -> [Tile] {
        guard let tree, let node = tree.resolve(viewCrumbs), size.width > 1, size.height > 1 else { return [] }
        let needle = filterCommitted ? liveFilter?.needle ?? "" : ""
        let key = "\(generation)|\(viewCrumbs)|\(Int(size.width))x\(Int(size.height))|\(depth)|\(options.metric)|\(needle)"
        return layoutCache.tiles(key: key) {
            layout(
                root: node,
                rootCrumbs: viewCrumbs,
                area: Rect(x: 0, y: 0, w: Double(size.width), h: Double(size.height)),
                metric: options.metric,
                options: LayoutOptions(maxDepth: depth, paddingOuter: 0),
                filter: filterCommitted ? liveFilter : nil
            )
        }
    }

    func trail() -> [CrumbItem] {
        guard !rootPath.isEmpty else { return [] }
        var items: [CrumbItem] = []
        let parts = rootPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        items.append(CrumbItem(id: "/", title: "/", path: "/", crumbs: rootPath == "/" ? [] : nil, dim: rootPath != "/"))
        var ancestorPath = ""
        for part in parts.dropLast() {
            ancestorPath += "/" + part
            items.append(CrumbItem(id: ancestorPath, title: part, path: ancestorPath, crumbs: nil, dim: true))
        }
        guard let tree else { return items }
        let chain = tree.resolveChain(viewCrumbs)
        var crumbs: [Int] = []
        for index in chain.indices {
            if !(index == 0 && rootPath == "/") {
                let title = index == 0 ? (parts.last ?? rootPath) : chain[index].name
                items.append(CrumbItem(
                    id: "in-\(crumbs.map(String.init).joined(separator: "."))",
                    title: title,
                    path: AppletreeCore.path(ofRoot: rootPath, node: tree, crumbs: crumbs),
                    crumbs: crumbs,
                    dim: false
                ))
            }
            if index < viewCrumbs.count {
                crumbs.append(viewCrumbs[index])
            }
        }
        return items
    }

    func siblings(of crumbs: [Int]) -> [(Int, Node)] {
        guard let tree, let node = tree.resolve(crumbs) else { return [] }
        return Array(node.children.prefix(24).enumerated().map { ($0.offset, $0.element) })
    }

    func openCrumb(_ item: CrumbItem) {
        if item.dim {
            let policy: VolumePolicy = item.path == "/" ? .startupDisk : .oneVolume
            let reuse = isWithin(rootPath, item.path) ? known : nil
            scan(path: item.path, policy: policy, known: reuse)
            return
        }
        if let crumbs = item.crumbs {
            show(crumbs)
        }
    }

    func jump(parent: [Int], child: Int) {
        enter(parent + [child])
    }

    func show(_ crumbs: [Int]) {
        viewCrumbs = crumbs
        if let node = tree?.resolve(crumbs) {
            selection = node.largestChild.map { crumbs + [$0] } ?? crumbs
        }
        transform = ViewTransform()
        keyboardOwnsSelection = true
    }

    func enter(_ crumbs: [Int]) {
        guard let node = tree?.resolve(crumbs), node.isDirectory else {
            selection = crumbs
            return
        }
        let origin = tileOnScreen(crumbs)
        let previous = snapshot()
        show(crumbs)
        if let origin, origin.width > 12, origin.height > 12 {
            backdrop = previous
            beginMotion(.zoomIn, focus: origin, duration: 0.42)
        }
    }

    func up() {
        guard !viewCrumbs.isEmpty else { return }
        let previous = snapshot()
        let leaving = viewCrumbs
        viewCrumbs = Array(viewCrumbs.dropLast())
        selection = leaving
        transform = ViewTransform()
        keyboardOwnsSelection = true
        if let tile = tiles(in: canvasSize).first(where: { $0.crumbs == leaving }) {
            let focus = CGRect(x: tile.rect.x, y: tile.rect.y, width: tile.rect.w, height: tile.rect.h)
            if focus.width > 12, focus.height > 12 {
                backdrop = previous
                beginMotion(.zoomOut, focus: focus, duration: 0.38)
            }
        }
    }

    private func snapshot() -> MosaicBackdrop? {
        guard let tree, canvasSize.width > 1, canvasSize.height > 1 else { return nil }
        return MosaicBackdrop(tree: tree, tiles: tiles(in: canvasSize), transform: transform)
    }

    private func tileOnScreen(_ crumbs: [Int]) -> CGRect? {
        guard canvasSize.width > 1,
              let tile = tiles(in: canvasSize).first(where: { $0.crumbs == crumbs }) else { return nil }
        return transform.screen(tile.rect)
    }

    private func beginMotion(_ kind: MosaicMotion.Kind, focus: CGRect, duration: TimeInterval) {
        let held = Launch.zoomEdge != nil
        let motion = MosaicMotion(kind: kind, started: Date(), duration: held ? 30 : duration, focus: focus)
        self.motion = motion
        let started = motion.started
        guard !held else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000) + 50_000_000)
            if self.motion?.started == started {
                self.motion = nil
                self.backdrop = nil
            }
        }
    }

    func enterEdge(_ edge: String) {
        guard canvasSize.width > 1, let tree else { return }
        let tiles = self.tiles(in: canvasSize).filter { $0.depth == 0 }
        // A name ("src") enters that top-level tile. top/bottom probe the left edge.
        if edge != "top", edge != "bottom",
           let tile = tiles.first(where: { tree.resolve($0.crumbs)?.name == edge }) {
            enter(tile.crumbs)
            return
        }
        let probeY = edge == "top" ? 24.0 : Double(canvasSize.height - 24)
        let tile = tiles.first { $0.rect.contains(12, probeY) }
        if let tile { enter(tile.crumbs) }
    }

    func noteCanvas(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard abs(size.width - canvasSize.width) > 0.5 || abs(size.height - canvasSize.height) > 0.5 else { return }
        canvasSize = size
    }

    func placement(at date: Date, canvas: CGSize) -> MosaicPlacement {
        guard let motion, canvas.width > 1, canvas.height > 1 else { return MosaicPlacement() }
        let t = motion.eased(at: date)
        switch motion.kind {
        case .intro:
            return MosaicPlacement(intro: t)
        case .zoomIn:
            // Map the new contents exactly onto the tile, then grow that
            // rectangle to the panel. A single scale centered on the tile
            // leaves a wide top tile starting in the middle of the panel.
            let full = CGRect(origin: .zero, size: canvas)
            let frame = lerp(motion.focus, full, t)
            return MosaicPlacement(
                scaleX: frame.width / canvas.width,
                scaleY: frame.height / canvas.height,
                offset: CGPoint(x: frame.minX, y: frame.minY),
                clip: frame
            )
        case .zoomOut:
            let full = CGRect(origin: .zero, size: canvas)
            let source = lerp(motion.focus, full, t)
            let scaleX = canvas.width / max(source.width, 1)
            let scaleY = canvas.height / max(source.height, 1)
            return MosaicPlacement(
                scaleX: scaleX,
                scaleY: scaleY,
                offset: CGPoint(x: -source.minX * scaleX, y: -source.minY * scaleY)
            )
        }
    }

    func select(_ crumbs: [Int]) {
        selection = crumbs
        if crumbs.count > viewCrumbs.count + 1 || !crumbs.starts(with: viewCrumbs) {
            viewCrumbs = Array(crumbs.dropLast())
            transform = ViewTransform()
        }
    }

    func toggleMark(_ crumbs: [Int]? = nil) {
        let crumbs = crumbs ?? activeCrumbs
        guard let crumbs, let tree, let node = tree.resolve(crumbs) else { return }
        let target = AppletreeCore.path(ofRoot: rootPath, node: tree, crumbs: crumbs)
        if target == rootPath || target == "/" { return }
        marks.toggle(Mark(path: target, bytes: node.bytes, hidden: node.name.hasPrefix(".")))
    }

    func pathFor(_ crumbs: [Int]) -> String? {
        guard let tree else { return nil }
        return AppletreeCore.path(ofRoot: rootPath, node: tree, crumbs: crumbs)
    }

    func isMarked(_ crumbs: [Int]) -> Bool {
        guard let path = pathFor(crumbs) else { return false }
        return marks.contains(path) || marks.covering(path) != nil
    }

    func isDimmed(_ crumbs: [Int]) -> Bool {
        guard let liveFilter, !filterCommitted else { return false }
        return liveFilter.keep(at: crumbs) == nil
    }

    func toggleMetric() {
        options.metric = options.metric.toggled
        guard var tree else { return }
        aggregate(&tree, metric: options.metric)
        self.tree = tree
        generation += 1
        layoutCache.clear()
    }

    func toggleApparent() {
        options.apparentSize.toggle()
        rescan()
    }

    func toggleHidden() {
        options.includeHidden.toggle()
        rescan()
    }

    func toggleColor() {
        colorMode = colorMode == .category ? .age : .category
    }

    func changeDepth(by delta: Int) {
        depth = min(6, max(1, depth + delta))
    }

    func commitFilter() {
        filterCommitted = !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearFilter() {
        filterText = ""
        filterCommitted = false
    }

    func move(_ direction: Direction) {
        let tiles = self.tiles(in: canvasSize).filter { $0.depth == 0 && !$0.crumbs.isEmpty }
        guard !tiles.isEmpty else { return }
        let current = tiles.first { $0.crumbs == selection } ?? tiles[0]
        let origin = CGPoint(x: current.rect.x + current.rect.w / 2, y: current.rect.y + current.rect.h / 2)
        let scored = tiles.compactMap { tile -> (Tile, Double)? in
            if tile.crumbs == current.crumbs { return nil }
            let center = CGPoint(x: tile.rect.x + tile.rect.w / 2, y: tile.rect.y + tile.rect.h / 2)
            let dx = center.x - origin.x
            let dy = center.y - origin.y
            let aligned: Bool
            switch direction {
            case .left: aligned = dx < -1 && abs(dx) >= abs(dy) * 0.5
            case .right: aligned = dx > 1 && abs(dx) >= abs(dy) * 0.5
            case .up: aligned = dy < -1 && abs(dy) >= abs(dx) * 0.5
            case .down: aligned = dy > 1 && abs(dy) >= abs(dx) * 0.5
            }
            guard aligned else { return nil }
            return (tile, dx * dx + dy * dy)
        }
        guard let next = scored.min(by: { $0.1 < $1.1 })?.0 else { return }
        selection = next.crumbs
        keyboardOwnsSelection = true
    }

    func tab() {
        guard let node = viewNode, !node.children.isEmpty else { return }
        let current = selection.starts(with: viewCrumbs) && selection.count == viewCrumbs.count + 1
            ? selection[viewCrumbs.count]
            : -1
        let next = (current + 1) % node.children.count
        selection = viewCrumbs + [next]
        keyboardOwnsSelection = true
    }

    func scroll(deltaX: CGFloat, deltaY: CGFloat, precise: Bool, shift: Bool, at point: CGPoint, size: CGSize) {
        canvasSize = size
        if shift {
            let dx = precise ? deltaX : deltaX * 40
            let dy = precise ? deltaY : deltaY * 40
            transform.origin.x -= dx / transform.scale
            transform.origin.y -= dy / transform.scale
            settledZoomAt = nil
            return
        }
        let factor = precise ? exp(deltaY * 0.01) : (deltaY > 0 ? 1.16 : 0.86)
        let raw = transform.scale * factor
        // Fully zoomed out is the original map: scale 1 and no pan. Leaving the
        // folder is a later notch, not the tail of the gesture that got us home.
        if deltaY < 0, transform == ViewTransform() {
            if precise, let settledZoomAt, Date().timeIntervalSince(settledZoomAt) < 0.4 {
                return
            }
            settledZoomAt = nil
            up()
            return
        }
        if deltaY < 0, raw <= 1 {
            transform = ViewTransform()
            settledZoomAt = precise ? Date() : nil
            return
        }
        settledZoomAt = nil
        let next = min(48, raw)
        let anchor = transform.base(point)
        transform.scale = next
        transform.origin = CGPoint(x: anchor.x - point.x / next, y: anchor.y - point.y / next)
        guard deltaY > 0 else { return }
        let tiles = tiles(in: size)
        let base = transform.base(point)
        guard let tile = hit(tiles, x: Double(base.x), y: Double(base.y)),
              let node = tree?.resolve(tile.crumbs), node.isDirectory else { return }
        let screen = transform.screen(tile.rect)
        if screen.width >= size.width * 0.92, screen.height >= size.height * 0.92 {
            enter(tile.crumbs)
        }
    }

    func hover(at point: CGPoint, size: CGSize) {
        canvasSize = size
        keyboardOwnsSelection = false
        let base = transform.base(point)
        hover = hit(tiles(in: size), x: Double(base.x), y: Double(base.y))?.crumbs
    }

    func click(at point: CGPoint, size: CGSize, command: Bool) {
        hover(at: point, size: size)
        guard let crumbs = hover else { return }
        if command {
            toggleMark(crumbs)
        } else {
            selection = crumbs
            keyboardOwnsSelection = false
        }
    }

    func doubleClick(at point: CGPoint, size: CGSize, command: Bool) {
        click(at: point, size: size, command: command)
        if let crumbs = hover, !command { enter(crumbs) }
    }

    func nodeMenu(at point: CGPoint, size: CGSize) -> NSMenu? {
        guard let tree else { return nil }
        let base = transform.base(point)
        guard let tile = hit(tiles(in: size), x: Double(base.x), y: Double(base.y)) else { return nil }
        selection = tile.crumbs
        keyboardOwnsSelection = true
        guard let node = tree.resolve(tile.crumbs) else { return nil }
        let path = AppletreeCore.path(ofRoot: rootPath, node: tree, crumbs: tile.crumbs)
        let menu = NSMenu()
        switch tile.kind {
        case .others(_, let count):
            menu.addItem(disabledItem("+\(count) smaller"))
            if tile.crumbs != viewCrumbs, node.isDirectory {
                menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.enter(tile.crumbs) })
            }
            menu.addItem(ClosureMenuItem("Reveal in Finder") { [weak self] in self?.reveal(path) })
            menu.addItem(ClosureMenuItem("Copy Path") { [weak self] in self?.copyPath(path) })
        case .node:
            let name = node.name.isEmpty ? path : node.name
            menu.addItem(disabledItem("\(name) — \(humanBytes(node.bytes))"))
            if node.isDirectory {
                menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.enter(tile.crumbs) })
            }
            menu.addItem(ClosureMenuItem("Reveal in Finder") { [weak self] in self?.reveal(path) })
            menu.addItem(ClosureMenuItem("Copy Path") { [weak self] in self?.copyPath(path) })
            menu.addItem(.separator())
            if path != rootPath, path != "/" {
                let title = markTitle(path: path)
                menu.addItem(ClosureMenuItem(title) { [weak self] in self?.toggleMark(tile.crumbs) })
            }
            let removal = plan(
                targets: [Target(path: path, bytes: node.bytes, hidden: node.name.hasPrefix("."))],
                root: rootPath
            )
            if let reason = removal.blocked.first?.reason {
                menu.addItem(disabledItem("Move to Trash"))
                menu.addItem(disabledItem(reason))
            } else if removal.targets.count == 1 {
                let name = node.name
                menu.addItem(ClosureMenuItem("Move to Trash") { [weak self] in self?.trash(tile.crumbs, name: name) })
            }
        }
        return menu
    }

    private func markTitle(path: String) -> String {
        if let cover = marks.covering(path) {
            return "Unmark \(URL(fileURLWithPath: cover.path).lastPathComponent)"
        }
        return marks.contains(path) ? "Unmark" : "Mark"
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func reveal(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            status = "Nothing on disk at \(path)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copyPath(_ path: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(path, forType: .string)
    }

    private func trash(_ crumbs: [Int], name: String) {
        guard !removing, let tree, let node = tree.resolve(crumbs) else { return }
        let path = AppletreeCore.path(ofRoot: rootPath, node: tree, crumbs: crumbs)
        let removal = plan(
            targets: [Target(path: path, bytes: node.bytes, hidden: node.name.hasPrefix("."))],
            root: rootPath
        )
        guard removal.targets.count == 1 else {
            status = removal.blocked.first?.reason
            return
        }
        removing = true
        Task {
            let failure: String? = await Task.detached {
                let note = OSAllocatedUnfairLock<String?>(initialState: nil)
                perform(removal, mode: .trash, onEvent: { event in
                    if case .item(_, _, let error?) = event {
                        note.withLock { $0 = error }
                    }
                })
                return note.withLock { $0 }
            }.value
            removing = false
            if let failure {
                status = "Couldn't move \(name) to the Trash. \(failure)"
                return
            }
            pendingSummary = "Moved \(name) to the Trash"
            rescan()
        }
    }

    func resetView() {
        transform = ViewTransform()
        settledZoomAt = nil
    }

    func magnify(by delta: CGFloat) {
        let next = min(48, max(1, transform.scale * delta))
        if next <= 1 {
            transform = ViewTransform()
        } else {
            transform.scale = next
        }
        settledZoomAt = nil
    }

    func openReview() {
        screen = .review
    }

    func commit(mode: RemovalMode) {
        let removal = removalPlan
        guard !removal.targets.isEmpty, !removing else { return }
        if mode == .permanent, !confirmingPermanent {
            confirmingPermanent = true
            return
        }
        confirmingPermanent = false
        removing = true
        let before = space?.available ?? 0
        let root = rootPath
        Task {
            await Task.detached {
                perform(removal, mode: mode)
            }.value
            let after = spaceInfo(path: root)?.available ?? before
            let gained = after > before ? after - before : 0
            pendingSummary = "Freed \(humanBytes(gained)) on disk"
            removing = false
            screen = .explore
            marks.removeAll()
            rescan()
        }
    }

    func openPrivacy() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    func handle(_ press: KeyPress, focusFilter: () -> Void) -> KeyPress.Result {
        if screen == .review {
            return handleReview(press)
        }
        switch press.key {
        case .return:
            if let crumbs = activeCrumbs { enter(crumbs) }
            return .handled
        case .escape:
            if showHelp { showHelp = false; return .handled }
            if !filterText.isEmpty { clearFilter(); return .handled }
            up()
            return .handled
        case .delete, .deleteForward:
            up()
            return .handled
        case .tab:
            tab()
            return .handled
        case .upArrow: move(.up); return .handled
        case .downArrow: move(.down); return .handled
        case .leftArrow: move(.left); return .handled
        case .rightArrow: move(.right); return .handled
        case .space:
            toggleMark()
            return .handled
        default:
            break
        }
        let characters = press.characters.lowercased()
        switch characters {
        case "x": toggleMark()
        case "/": focusFilter()
        case "[": changeDepth(by: -1)
        case "]": changeDepth(by: 1)
        case "-", "_": magnify(by: 0.85)
        case "=", "+": magnify(by: 1.18)
        case "0": resetView()
        case "c": openReview()
        case "t": toggleMetric()
        case "d": toggleApparent()
        case "i": toggleHidden()
        case "a": toggleColor()
        case "r": rescan()
        case "g": scanStartupDisk()
        case "p": showSelection.toggle()
        case "?": showHelp.toggle()
        default: return .ignored
        }
        return .handled
    }

    private func handleReview(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            if confirmingPermanent { confirmingPermanent = false } else { screen = .explore }
            return .handled
        case .return:
            commit(mode: .trash)
            return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "t": commit(mode: .trash)
        case "p": commit(mode: .permanent)
        case "!": marks.removeAll()
        default: return .ignored
        }
        return .handled
    }
}

enum Direction {
    case left, right, up, down
}

struct MosaicBackdrop {
    var tree: Node
    var tiles: [Tile]
    var transform: ViewTransform
}

struct MosaicMotion: Equatable {
    enum Kind: Equatable {
        case intro
        case zoomIn
        case zoomOut
    }

    var kind: Kind
    var started: Date
    var duration: TimeInterval
    var focus: CGRect

    func eased(at date: Date) -> CGFloat {
        let raw = min(1, max(0, date.timeIntervalSince(started) / duration))
        let t = CGFloat(raw)
        return t * t * (3 - 2 * t)
    }
}

struct MosaicPlacement: Equatable {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var offset: CGPoint = .zero
    var clip: CGRect?
    var intro: CGFloat?
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
}

private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
}

private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(
        x: lerp(a.minX, b.minX, t),
        y: lerp(a.minY, b.minY, t),
        width: lerp(a.width, b.width, t),
        height: lerp(a.height, b.height, t)
    )
}

private final class LayoutCache {
    var key = ""
    var tiles: [Tile] = []

    func tiles(key: String, make: () -> [Tile]) -> [Tile] {
        if key == self.key { return tiles }
        let made = make()
        self.key = key
        self.tiles = made
        return made
    }

    func clear() {
        key = ""
        tiles = []
    }
}

enum Launch {
    nonisolated(unsafe) static var demo = false
    nonisolated(unsafe) static var screenshotPath: String?
    /// `top` or `bottom`: enter that edge's tile and hold the zoom at its start.
    nonisolated(unsafe) static var zoomEdge: String?
    /// A path argument or `--disk` starts a scan. A plain launch waits for a choice.
    nonisolated(unsafe) static var scansOnLaunch = false

    static func parse() -> (root: String, options: ScanOptions, depth: Int) {
        var options = ScanOptions()
        var root: String?
        var disk = false
        var depth = 3
        var arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--apparent-size":
                options.apparentSize = true
            case "--follow-links":
                options.followLinks = true
            case "--no-hidden":
                options.includeHidden = false
            case "--cross-filesystems":
                options.volumePolicy = .unrestricted
            case "--demo":
                demo = true
            case "--screenshot":
                index += 1
                if index < arguments.count {
                    screenshotPath = arguments[index]
                }
            case "--zoom":
                index += 1
                if index < arguments.count {
                    zoomEdge = arguments[index]
                    demo = true
                }
            case "--disk":
                disk = true
            case "--depth":
                index += 1
                if index < arguments.count, let value = Int(arguments[index]) {
                    depth = min(6, max(1, value))
                }
            default:
                if argument.hasPrefix("-") {
                    // Xcode launches with pairs such as -NSDocumentRevisionsDebugMode YES.
                    // The value is not a folder.
                    if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                        index += 1
                    }
                } else if root == nil, looksLikePath(argument) {
                    root = argument
                }
            }
            index += 1
        }
        if disk {
            if options.volumePolicy != .unrestricted {
                options.volumePolicy = .startupDisk
            }
            scansOnLaunch = true
            return ("/", options, depth)
        }
        if let root {
            let expanded = (root as NSString).expandingTildeInPath
            scansOnLaunch = true
            return (normalize(path: URL(fileURLWithPath: expanded).path), options, depth)
        }
        return ("", options, depth)
    }
}

private func looksLikePath(_ argument: String) -> Bool {
    argument.hasPrefix("/") || argument.hasPrefix("~") || argument.hasPrefix(".") || argument.contains("/")
}
