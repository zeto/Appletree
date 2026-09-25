import Foundation

public struct Rect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var right: Double { x + w }
    public var bottom: Double { y + h }
    public var area: Double { max(0, w) * max(0, h) }

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && px < right && py >= y && py < bottom
    }

    public func inset(_ padding: Double) -> Rect {
        Rect(
            x: x + padding,
            y: y + padding,
            w: max(0, w - padding * 2),
            h: max(0, h - padding * 2)
        )
    }
}

public enum TileKind: Sendable, Equatable {
    case node(crumbs: [Int])
    case others(crumbs: [Int], count: Int)
}

public struct Tile: Sendable, Equatable {
    public var kind: TileKind
    public var rect: Rect
    public var depth: Int
    public var header: Rect?

    public var crumbs: [Int] {
        switch kind {
        case .node(let crumbs), .others(let crumbs, _):
            crumbs
        }
    }

    public init(kind: TileKind, rect: Rect, depth: Int, header: Rect?) {
        self.kind = kind
        self.rect = rect
        self.depth = depth
        self.header = header
    }
}

public struct LayoutOptions: Sendable, Equatable {
    public var maxDepth: Int
    public var padding: Double
    public var paddingOuter: Double
    public var minTile: Double
    public var maxChildren: Int
    public var header: Double
    public var headerInner: Double

    public init(
        maxDepth: Int = 3,
        padding: Double = 1,
        paddingOuter: Double = 3,
        minTile: Double = 5,
        maxChildren: Int = 96,
        header: Double = 20,
        headerInner: Double = 15
    ) {
        self.maxDepth = maxDepth
        self.padding = padding
        self.paddingOuter = paddingOuter
        self.minTile = minTile
        self.maxChildren = maxChildren
        self.header = header
        self.headerInner = headerInner
    }
}

public func layout(
    root: Node,
    rootCrumbs: [Int],
    area: Rect,
    metric: Metric,
    options: LayoutOptions = LayoutOptions(),
    filter: Matches? = nil
) -> [Tile] {
    var tiles: [Tile] = []
    var crumbs = rootCrumbs
    placeChildren(
        root,
        area: area,
        metric: metric,
        options: options,
        filter: filter,
        depth: 0,
        crumbs: &crumbs,
        out: &tiles
    )
    return tiles
}

private func placeChildren(
    _ node: Node,
    area: Rect,
    metric: Metric,
    options: LayoutOptions,
    filter: Matches?,
    depth: Int,
    crumbs: inout [Int],
    out: inout [Tile]
) {
    if node.children.isEmpty || area.w <= 0 || area.h <= 0 { return }

    var ranked: [(index: Int, value: Double)] = []
    for (index, child) in node.children.enumerated() {
        let value: Double
        if let filter {
            crumbs.append(index)
            let keep = filter.keep(at: crumbs)
            crumbs.removeLast()
            guard let keep else { continue }
            value = Double(Matches.value(keep, node: child, metric: metric))
        } else {
            value = Double(child.value(metric))
        }
        if value > 0 {
            ranked.append((index, value))
        }
    }
    if ranked.isEmpty { return }
    ranked.sort { $0.value > $1.value }

    let kept = min(ranked.count, options.maxChildren)
    var values = ranked.prefix(kept).map(\.value)
    var sources: [Int?] = ranked.prefix(kept).map { Optional($0.index) }
    let tailCount = ranked.count - kept
    if tailCount > 0 {
        values.append(ranked.dropFirst(kept).reduce(0) { $0 + $1.value })
        sources.append(nil)
    }

    let placed = squarify(values, area: area)
    for (slot, raw) in placed.enumerated() {
        let rect = raw.inset(depth == 0 ? options.paddingOuter : options.padding)
        if rect.w < options.minTile || rect.h < options.minTile { continue }
        guard let index = sources[slot] else {
            out.append(Tile(kind: .others(crumbs: crumbs, count: tailCount), rect: rect, depth: depth, header: nil))
            continue
        }
        let child = node.children[index]
        let subdividable = child.isDirectory && depth + 1 < options.maxDepth
        let header = subdividable ? headerBand(rect, options: options, depth: depth) : nil
        crumbs.append(index)
        out.append(Tile(kind: .node(crumbs: crumbs), rect: rect, depth: depth, header: header))
        if let header {
            let body = Rect(x: rect.x, y: header.bottom, w: rect.w, h: rect.bottom - header.bottom)
            let innerFilter: Matches? = {
                guard let filter else { return nil }
                if filter.keep(at: crumbs) == .whole { return nil }
                return filter
            }()
            placeChildren(
                child,
                area: body,
                metric: metric,
                options: options,
                filter: innerFilter,
                depth: depth + 1,
                crumbs: &crumbs,
                out: &out
            )
        }
        crumbs.removeLast()
    }
}

private func headerBand(_ rect: Rect, options: LayoutOptions, depth: Int) -> Rect? {
    let height = depth == 0 ? options.header : options.headerInner
    let body = rect.h - height
    if rect.w < 44 || body < options.minTile * 3 { return nil }
    return Rect(x: rect.x, y: rect.y, w: rect.w, h: height)
}

public func squarify(_ values: [Double], area: Rect) -> [Rect] {
    var rects = Array(repeating: Rect(x: 0, y: 0, w: 0, h: 0), count: values.count)
    let total = values.reduce(0) { $1 > 0 ? $0 + $1 : $0 }
    if total <= 0 || area.w <= 0 || area.h <= 0 { return rects }

    var order = values.indices.filter { values[$0] > 0 }
    order.sort { values[$0] > values[$1] }
    let scale = area.w * area.h / total
    let areas = order.map { values[$0] * scale }

    var free = area
    var start = 0
    while start < areas.count {
        let side = min(free.w, free.h)
        var end = start + 1
        var rowSum = areas[start]
        var rowWorst = worstRatio(Array(areas[start..<end]), rowSum: rowSum, side: side)
        while end < areas.count {
            let candidateSum = rowSum + areas[end]
            let candidateWorst = worstRatio(Array(areas[start...end]), rowSum: candidateSum, side: side)
            if candidateWorst > rowWorst { break }
            rowSum = candidateSum
            rowWorst = candidateWorst
            end += 1
        }

        if free.w >= free.h {
            let stripW = min(free.w, rowSum / free.h)
            var y = free.y
            for index in start..<end {
                let height = stripW > 0 ? min(free.bottom - y, areas[index] / stripW) : 0
                let clamped = max(0, height)
                rects[order[index]] = Rect(x: free.x, y: y, w: stripW, h: clamped)
                y += clamped
            }
            free.x += stripW
            free.w -= stripW
        } else {
            let stripH = min(free.h, rowSum / free.w)
            var x = free.x
            for index in start..<end {
                let width = stripH > 0 ? min(free.right - x, areas[index] / stripH) : 0
                let clamped = max(0, width)
                rects[order[index]] = Rect(x: x, y: free.y, w: clamped, h: stripH)
                x += clamped
            }
            free.y += stripH
            free.h -= stripH
        }
        start = end
    }
    return rects
}

private func worstRatio(_ areas: [Double], rowSum: Double, side: Double) -> Double {
    if rowSum <= 0 || side <= 0 { return .infinity }
    let thickness = rowSum / side
    var worst = 0.0
    for area in areas {
        if area <= 0 || thickness <= 0 { continue }
        let other = area / thickness
        let ratio = max(thickness / other, other / thickness)
        worst = max(worst, ratio)
    }
    return worst
}

public func hit(_ tiles: [Tile], x: Double, y: Double) -> Tile? {
    tiles.reversed().first { $0.rect.contains(x, y) }
}
