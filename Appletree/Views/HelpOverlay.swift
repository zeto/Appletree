import SwiftUI

struct HelpOverlay: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keys")
                .font(.headline)
            grid([
                ("space, x", "mark or unmark"),
                ("return", "open the directory"),
                ("right-click", "open, reveal, mark, trash"),
                ("delete, esc", "up one directory"),
                ("arrows", "move between tiles"),
                ("tab", "next largest sibling"),
                ("scroll", "zoom, then enter"),
                ("shift-scroll", "pan"),
                ("[ ]", "fewer or more levels"),
                ("− = 0", "magnify, shrink, reset"),
                ("/", "filter"),
                ("c", "review marks"),
                ("t", "size or file count"),
                ("d", "allocated or apparent"),
                ("i", "hidden files"),
                ("a", "kind or age"),
                ("r", "scan again"),
                ("g", "startup disk"),
                ("p", "selection details"),
                ("?", "this list"),
            ])
            Text("On review: t trash, p permanent, ! unmark all, return commits, esc back.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
    }

    private func grid(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(rows, id: \.0) { key, action in
                GridRow {
                    Text(key).font(.system(.body, design: .monospaced))
                    Text(action).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}
