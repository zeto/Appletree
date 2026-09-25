import AppKit
import SwiftUI

struct ScrollMonitor: NSViewRepresentable {
    var onScroll: (NSEvent, CGPoint, CGSize) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScroll = onScroll
    }
}

final class MonitorView: NSView {
    var onScroll: ((NSEvent, CGPoint, CGSize) -> Bool)?
    nonisolated(unsafe) private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }
            let flipped = CGPoint(x: local.x, y: self.bounds.height - local.y)
            if self.onScroll?(event, flipped, self.bounds.size) == true {
                return nil
            }
            return event
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

struct NodeMenuMonitor: NSViewRepresentable {
    var onRightClick: (CGPoint, CGSize) -> NSMenu?

    func makeNSView(context: Context) -> NodeMenuView {
        let view = NodeMenuView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: NodeMenuView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

final class NodeMenuView: NSView {
    var onRightClick: ((CGPoint, CGSize) -> NSMenu?)?
    nonisolated(unsafe) private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }
            let flipped = CGPoint(x: local.x, y: self.bounds.height - local.y)
            guard let menu = self.onRightClick?(flipped, self.bounds.size) else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.isEnabled = enabled
    }

    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem is built in code")
    }

    @objc private func fire() {
        handler()
    }
}
