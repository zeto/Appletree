import AppKit
import AppletreeCore
import SwiftUI

struct TreemapCanvas: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var windowCorners = WindowCorners.current

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let tiles = model.tiles(in: size)
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: model.motion == nil)) { timeline in
                let placement = model.placement(at: timeline.date, canvas: size)
                Canvas { context, _ in
                    var context = context
                    let now = Int64(Date().timeIntervalSince1970)
                    if let clip = windowCorners.clip {
                        context.clip(to: Path(clip))
                    }
                    if let backdrop = model.backdrop,
                       let kind = model.motion?.kind, kind != .intro {
                        var still = context
                        for tile in backdrop.tiles {
                            draw(
                                tile,
                                in: &still,
                                now: now,
                                intro: nil,
                                canvas: size,
                                tree: backdrop.tree,
                                transform: backdrop.transform
                            )
                        }
                    }
                    if let clip = placement.clip {
                        context.clip(to: Path(clip))
                    }
                    if placement.scaleX != 1 || placement.scaleY != 1 || placement.offset != .zero {
                        context.translateBy(x: placement.offset.x, y: placement.offset.y)
                        context.scaleBy(x: placement.scaleX, y: placement.scaleY)
                    }
                    guard let tree = model.tree else { return }
                    for tile in tiles {
                        draw(
                            tile,
                            in: &context,
                            now: now,
                            intro: placement.intro,
                            canvas: size,
                            tree: tree,
                            transform: model.transform
                        )
                    }
                    if let selected = tiles.first(where: { $0.crumbs == model.selection })
                        ?? tiles.first(where: { model.selection.starts(with: $0.crumbs) && $0.crumbs != model.viewCrumbs }) {
                        let rect = model.transform.screen(selected.rect)
                        let settled = abs(placement.scaleX - 1) < 0.02
                            && abs(placement.scaleY - 1) < 0.02
                            && placement.offset == .zero
                        let strokeScale = max(placement.scaleX, placement.scaleY)
                        strokeSelection(
                            around: rect,
                            in: &context,
                            canvas: size,
                            corners: settled ? windowCorners : WindowCorners(radius: windowCorners.radius),
                            lineWidth: 2 / max(strokeScale, 0.01)
                        )
                    }
                }
            }
            .background(scheme == .dark ? Color(white: 0.08) : Color(white: 0.94))
            .gesture(clickGesture(size: size))
            .onContinuousHover { phase in
                if case .active(let point) = phase {
                    model.hover(at: point, size: size)
                }
            }
            .background {
                ZStack {
                    WindowCornerReader { windowCorners = $0 }
                    ScrollMonitor { event, point, viewSize in
                    model.scroll(
                        deltaX: event.scrollingDeltaX,
                        deltaY: event.scrollingDeltaY,
                        precise: event.hasPreciseScrollingDeltas,
                        shift: event.modifierFlags.contains(.shift),
                        at: point,
                        size: viewSize
                    )
                    return true
                    }
                    NodeMenuMonitor { point, viewSize in
                        model.nodeMenu(at: point, size: viewSize)
                    }
                }
            }
            .onAppear { model.noteCanvas(size) }
            .onChange(of: size) { _, newSize in
                model.noteCanvas(newSize)
                model.selectBottomLeft(in: newSize)
            }
            .onChange(of: model.generation) {
                model.selectBottomLeft(in: size)
            }
            .overlay {
                if model.scanning, model.tree == nil {
                    ProgressView("Scanning \(model.progress.files.formatted()) files")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    @State private var lastClick = Date.distantPast

    private func clickGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard hypot(value.translation.width, value.translation.height) < 4 else { return }
                let now = Date()
                if now.timeIntervalSince(lastClick) < 0.35 {
                    model.doubleClick(at: value.location, size: size, command: false)
                    lastClick = .distantPast
                } else {
                    model.click(at: value.location, size: size, command: NSEvent.modifierFlags.contains(.command))
                    lastClick = now
                }
            }
    }

    private func draw(
        _ tile: Tile,
        in context: inout GraphicsContext,
        now: Int64,
        intro: CGFloat?,
        canvas: CGSize,
        tree: Node,
        transform: ViewTransform
    ) {
        var rect = bleed(transform.screen(tile.rect), canvas: canvas, corners: windowCorners)
        var opacity: CGFloat = 1
        if let intro {
            let local = introAmount(tile: tile, progress: intro, canvas: canvas)
            opacity = local
            let scale = 0.9 + 0.1 * local
            rect = CGRect(
                x: rect.midX - rect.width * scale / 2,
                y: rect.midY - rect.height * scale / 2,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }
        guard rect.width >= 1, rect.height >= 1, opacity > 0.02 else { return }
        var layer = context
        layer.opacity = opacity
        layer.clip(to: Path(rect))
        let node = tree.resolve(tile.crumbs)
        let marked = model.isMarked(tile.crumbs)
        let dimmed = model.isDimmed(tile.crumbs)
        let fill: Color
        if marked {
            fill = danger.opacity(0.85)
        } else if case .others = tile.kind {
            fill = scheme == .dark ? Color(white: 0.2) : Color(white: 0.82)
        } else if model.colorMode == .age {
            fill = ageFill(ageBucket(modified: node?.modified ?? 0, now: now), depth: tile.depth, scheme: scheme)
        } else {
            fill = categoryFill(node?.category ?? .other, depth: tile.depth, scheme: scheme)
        }
        layer.fill(Path(rect), with: .color(dimmed ? fill.opacity(0.18) : fill))
        if node?.reclaim != nil, rect.width > 14, rect.height > 14 {
            strokeHatch(in: &layer, rect: rect)
        }
        if tile.depth == 0, let node, case .node = tile.kind {
            let strip = CGRect(x: rect.minX, y: rect.minY, width: 4, height: rect.height)
            layer.fill(Path(strip), with: .color(categoryAccent(node.category, scheme: scheme)))
        }
        if let header = tile.header {
            var band = transform.screen(header)
            if intro != nil {
                let base = transform.screen(tile.rect)
                let scale = rect.width / max(base.width, 1)
                let center = CGPoint(x: base.midX, y: base.midY)
                band = CGRect(
                    x: center.x + (band.minX - center.x) * scale,
                    y: center.y + (band.minY - center.y) * scale,
                    width: band.width * scale,
                    height: band.height * scale
                )
            }
            let title = node?.name ?? ""
            drawLabel(title, in: band.insetBy(dx: 8, dy: 1), context: &layer, strong: true)
        } else if rect.width > 48, rect.height > 16 {
            let title: String
            switch tile.kind {
            case .others(_, let count):
                title = "+\(count)"
            case .node:
                title = node?.name ?? ""
            }
            drawLabel(title, in: rect.insetBy(dx: 6, dy: 3), context: &layer, strong: tile.depth == 0)
        }
    }

    private func introAmount(tile: Tile, progress: CGFloat, canvas: CGSize) -> CGFloat {
        let area = max(Double(canvas.width * canvas.height), 1)
        let share = (tile.rect.w * tile.rect.h) / area
        let stagger = CGFloat(min(0.4, (1 - min(1, share * 3)) * 0.32 + Double(tile.depth) * 0.05))
        let t = (progress - stagger) / 0.4
        let clamped = min(1, max(0, t))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func drawLabel(_ text: String, in rect: CGRect, context: inout GraphicsContext, strong: Bool) {
        guard rect.width > 8, rect.height > 8, !text.isEmpty else { return }
        let label = Text(text)
            .font(.system(size: strong ? 12 : 10, weight: strong ? .semibold : .regular))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.8))
        context.draw(context.resolve(label), in: rect)
    }

    /// Stroke the tile from the inside. Where the tile covers a window corner, the
    /// line is the inner half of a stroke centered on the window's own curve, so
    /// it follows that corner instead of cutting across it.
    private func strokeSelection(
        around tile: CGRect,
        in context: inout GraphicsContext,
        canvas: CGSize,
        corners: WindowCorners,
        lineWidth: CGFloat
    ) {
        let aligned = bleed(tile, canvas: canvas, corners: corners)
        let windowShape = corners.clip.map { Path($0) } ?? windowOutline(CGRect(origin: .zero, size: canvas), corners: corners)
        let onWindow = corners.clip != nil
        var layer = context
        if onWindow {
            layer.clip(to: windowShape)
        }
        layer.clip(to: Path(aligned))
        layer.stroke(Path(aligned), with: .color(highlight), lineWidth: lineWidth * 2)
        if onWindow {
            layer.stroke(windowShape, with: .color(highlight), lineWidth: lineWidth * 2)
        }
    }

    private func bleed(_ rect: CGRect, canvas: CGSize, corners: WindowCorners) -> CGRect {
        var aligned = rect
        let slack: CGFloat = 3
        if (corners.topLeading || corners.bottomLeading), aligned.minX <= slack {
            aligned.size.width += aligned.minX
            aligned.origin.x = 0
        }
        if (corners.topTrailing || corners.bottomTrailing), aligned.maxX >= canvas.width - slack {
            aligned.size.width += canvas.width - aligned.maxX
        }
        if (corners.topLeading || corners.topTrailing), aligned.minY <= slack {
            aligned.size.height += aligned.minY
            aligned.origin.y = 0
        }
        if (corners.bottomLeading || corners.bottomTrailing), aligned.maxY >= canvas.height - slack {
            aligned.size.height += canvas.height - aligned.maxY
        }
        return aligned
    }

    private func windowOutline(_ rect: CGRect, corners: WindowCorners) -> Path {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: corners.topLeading ? corners.radius : 0,
                bottomLeading: corners.bottomLeading ? corners.radius : 0,
                bottomTrailing: corners.bottomTrailing ? corners.radius : 0,
                topTrailing: corners.topTrailing ? corners.radius : 0
            ),
            style: .continuous
        ).path(in: rect)
    }

    private func strokeHatch(in context: inout GraphicsContext, rect: CGRect) {
        var y = rect.minY - rect.width
        let end = rect.maxY
        while y < end {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y + rect.width))
            context.stroke(path, with: .color(hatchColor), lineWidth: 1)
            y += 8
        }
    }
}

struct WindowCorners: Equatable {
    var radius: CGFloat
    var topLeading = false
    var bottomLeading = false
    var bottomTrailing = false
    var topTrailing = false
    /// The window's real corner path, in this view's top-left coordinate space.
    var clip: CGPath?

    static var current: WindowCorners {
        WindowCorners(radius: 16)
    }

    static func == (lhs: WindowCorners, rhs: WindowCorners) -> Bool {
        lhs.radius == rhs.radius
            && lhs.topLeading == rhs.topLeading
            && lhs.bottomLeading == rhs.bottomLeading
            && lhs.bottomTrailing == rhs.bottomTrailing
            && lhs.topTrailing == rhs.topTrailing
            && lhs.clip?.boundingBox == rhs.clip?.boundingBox
    }
}

func windowCornerRadius(_ window: NSWindow) -> CGFloat {
    if let number = window.value(forKey: "_cornerRadius") as? NSNumber {
        return max(0, CGFloat(truncating: number))
    }
    return 16
}

/// The window server's corner path, converted into `view` with y growing downward.
func windowClipPath(in view: NSView, window: NSWindow) -> CGPath? {
    guard let theme = window.contentView?.superview else { return nil }
    let selector = NSSelectorFromString("_getCachedWindowCornerPath")
    guard theme.responds(to: selector),
          let raw = theme.perform(selector)?.takeUnretainedValue() else { return nil }
    let cf = raw as CFTypeRef
    guard CFGetTypeID(cf) == CGPath.typeID else { return nil }
    let path = cf as! CGPath
    let frame = view.convert(view.bounds, to: theme)
    var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -frame.minX, ty: frame.maxY)
    return path.copy(using: &transform)
}

struct WindowCornerReader: NSViewRepresentable {
    var onChange: (WindowCorners) -> Void

    func makeNSView(context: Context) -> WindowCornerProbe {
        let view = WindowCornerProbe()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowCornerProbe, context: Context) {
        nsView.onChange = onChange
        nsView.publish()
    }
}

final class WindowCornerProbe: NSView {
    var onChange: ((WindowCorners) -> Void)?
    private var last: WindowCorners?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        publish()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publish()
    }

    func publish() {
        guard let window, let content = window.contentView, bounds.width > 1, bounds.height > 1 else { return }
        // Window coordinates are y-up. Comparing against the content view here
        // keeps the bottom of the map from being reported as its top.
        let frame = convert(bounds, to: nil)
        let limit = content.convert(content.bounds, to: nil)
        let slack: CGFloat = 2
        let corners = WindowCorners(
            radius: windowCornerRadius(window),
            topLeading: frame.maxY >= limit.maxY - slack && frame.minX <= limit.minX + slack,
            bottomLeading: frame.minY <= limit.minY + slack && frame.minX <= limit.minX + slack,
            bottomTrailing: frame.minY <= limit.minY + slack && frame.maxX >= limit.maxX - slack,
            topTrailing: frame.maxY >= limit.maxY - slack && frame.maxX >= limit.maxX - slack,
            clip: windowClipPath(in: self, window: window)
        )
        guard corners != last else { return }
        last = corners
        onChange?(corners)
    }
}
