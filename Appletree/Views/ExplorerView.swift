import AppKit
import AppletreeCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ExplorerView: View {
    @Bindable var model: AppModel
    @FocusState private var focus: FocusField?
    @Environment(\.colorScheme) private var scheme
    @State private var dividerStart: CGFloat?

    private enum FocusField: Hashable {
        case canvas
        case filter
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            measure
            if let status = model.status, !model.awaitsScan {
                Text(status)
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            if model.screen == .review {
                ReviewView(model: model)
            } else {
                mosaic
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.96))
        .background(WindowBackground(color: scheme == .dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.96, alpha: 1)))
        .ignoresSafeArea(edges: .bottom)
        .overlay {
            if model.showHelp {
                HelpOverlay()
                    .onTapGesture { model.showHelp = false }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .canvas)
        .onAppear { focus = .canvas; model.start() }
        .task {
            guard let path = Launch.screenshotPath else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if let edge = Launch.zoomEdge {
                model.enterEdge(edge)
                try? await Task.sleep(for: .milliseconds(120))
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
            WindowCapture.write(to: path)
            NSApp.terminate(nil)
        }
        .onKeyPress(phases: .down) { press in
            if focus == .filter {
                if press.key == .escape {
                    model.clearFilter()
                    focus = .canvas
                    return .handled
                }
                if press.key == .return {
                    model.commitFilter()
                    focus = .canvas
                    return .handled
                }
                return .ignored
            }
            return model.handle(press) { focus = .filter }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let item = item as? URL {
                    url = item
                } else {
                    url = nil
                }
                guard let url else { return }
                Task { @MainActor in model.scanDropped(url) }
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BreadcrumbBar(model: model)
            Spacer(minLength: 8)
            TextField("Filter", text: $model.filterText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($focus, equals: .filter)
                .onSubmit {
                    model.commitFilter()
                    focus = .canvas
                }
        }
        .padding(.trailing, 16)
    }

    private var measure: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let tree = model.tree {
                    Text("\(humanBytes(tree.bytes)) · \(humanCount(tree.files)) files")
                        .font(.callout.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                } else if model.scanning {
                    Text("Scanning \(model.progress.files.formatted()) files")
                        .font(.callout)
                        .lineLimit(1)
                }
                if model.scanning, model.tree != nil {
                    ProgressView().controlSize(.small)
                }
                if let error = model.scanError, model.tree != nil {
                    Text(error).foregroundStyle(.orange).lineLimit(1)
                }
                Spacer(minLength: 8)
                Picker("Metric", selection: $model.options.metric) {
                    Text("Size").tag(Metric.bytes)
                    Text("Files").tag(Metric.files)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
                .fixedSize(horizontal: true, vertical: true)
                .onChange(of: model.options.metric) { _, metric in
                    guard var tree = model.tree else { return }
                    aggregate(&tree, metric: metric)
                    model.tree = tree
                    model.generation += 1
                }
                measureButton(model.colorMode.label) { model.toggleColor() }
                measureButton(model.options.includeHidden ? "Hidden" : "No hidden") { model.toggleHidden() }
                measureButton(model.options.apparentSize ? "Apparent" : "On disk") { model.toggleApparent() }
                Text("Depth \(model.depth)")
                    .font(.callout)
                    .lineLimit(1)
                    .fixedSize()
            }
            if model.colorMode == .category {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(AppletreeCore.Category.legend, id: \.self) { category in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(categoryAccent(category, scheme: scheme))
                                    .frame(width: 10, height: 10)
                                Text(category.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .buttonStyle(.borderless)
    }

    private func measureButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder private var mosaic: some View {
        if model.awaitsScan {
            welcome
        } else {
            HStack(spacing: 0) {
                TreemapCanvas(model: model)
                divider
                InspectorView(model: model)
                    .frame(width: model.panelWidth)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("See what fills the disk")
                    .font(.title2.weight(.semibold))
                Text("Pick a folder to draw the map.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Scan Folder…", action: model.openFolder)
                    .buttonStyle(.borderedProminent)
                    .tint(highlight)
                Button("Scan Home", action: model.scanHome)
                    .buttonStyle(.bordered)
                Button("Scan Startup Disk", action: model.scanStartupDisk)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            if let error = model.scanError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dividerStart == nil { dividerStart = model.panelWidth }
                        let width = (dividerStart ?? model.panelWidth) - value.translation.width
                        model.panelWidth = min(model.rem * 44, max(model.rem * 17, width))
                    }
                    .onEnded { _ in dividerStart = nil }
            )
            .onTapGesture(count: 2) { model.panelWidth = model.rem * 23 }
    }
}

/// The window's own backing is white. Match it to the interface so a corner fringe cannot show as a white gap.
enum WindowCapture {
    static func write(to path: String) {
        let window = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
        guard let window else {
            try? "no window".write(toFile: path + ".err", atomically: true, encoding: .utf8)
            return
        }
        let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        )
        guard let image else {
            try? "capture failed".write(toFile: path + ".err", atomically: true, encoding: .utf8)
            return
        }
        save(image, to: path)
        let cropWidth = min(420, image.width)
        let cropHeight = min(320, image.height)
        let crop = CGRect(x: 0, y: max(0, image.height - cropHeight), width: cropWidth, height: cropHeight)
        if let corner = image.cropping(to: crop) {
            let cornerPath = (path as NSString).deletingPathExtension + "-corner.png"
            save(corner, to: cornerPath)
        } else {
            try? "crop failed \(image.width)x\(image.height)".write(toFile: path + ".err", atomically: true, encoding: .utf8)
        }
    }

    private static func save(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

private struct WindowBackground: NSViewRepresentable {
    var color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.backgroundColor = color
        nsView.window?.isOpaque = true
    }
}
