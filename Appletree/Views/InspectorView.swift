import AppletreeCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.showSelection {
                        selection
                    }
                    findings
                    marked
                    disk
                    Text("Allocated size matches du. Cloned files can share blocks, so deleting them may free less than the sum of the marks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            reviewBar
        }
        .background(.bar)
    }

    private var reviewBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(model.marks.marks.isEmpty ? "Review…" : "Review \(model.marks.marks.count)…") {
                model.openReview()
            }
            .buttonStyle(.borderedProminent)
            .tint(highlight)
            .frame(maxWidth: .infinity)
            Text(model.marks.marks.isEmpty ? "Opens the list. Mark a tile first if it is empty." : "Trash is recoverable. Permanent deletion asks first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder private var selection: some View {
        if let tree = model.tree, let node = model.selectedNode {
            let total = max(tree.bytes, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name.isEmpty ? "/" : node.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                Text(humanBytes(node.bytes))
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundStyle(highlight)
                Text("\(Int(share(part: node.bytes, total: total)))% of the scan · \(humanCount(node.files)) files")
                    .foregroundStyle(.secondary)
                if node.isDirectory {
                    Text("\(humanBytes(node.ownBytes)) in this directory · \(humanCount(node.dirs)) folders")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if node.modified > 0 {
                    Text(Date(timeIntervalSince1970: TimeInterval(node.modified)).formatted(date: .abbreviated, time: .shortened))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if node.dataless {
                    Text("Not downloaded from iCloud")
                        .font(.callout)
                }
                if node.readError {
                    Text("Could not read this directory")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let reclaim = node.reclaim {
                    Text(reclaim.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(highlight)
                }
                if let path = model.pathFor(model.selection), path != model.rootPath, path != "/" {
                    if let cover = model.marks.covering(path) {
                        Button("Unmark \(URL(fileURLWithPath: cover.path).lastPathComponent)") {
                            model.marks.remove(cover.path)
                        }
                    } else {
                        Button(model.isMarked(model.selection) ? "Unmark" : "Mark") {
                            model.toggleMark(model.selection)
                        }
                    }
                }
            }
        } else {
            Text(model.scanning ? "Scanning…" : "Select a tile")
                .foregroundStyle(.secondary)
        }
    }

    private var findings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Worth a look")
                .font(.headline)
            if model.findings.isEmpty {
                Text("Nothing large enough to suggest.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.findings) { candidate in
                    Button {
                        model.select(candidate.crumbs)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.tree?.resolve(candidate.crumbs)?.name ?? "Item")
                                Text(candidate.finding.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(humanBytes(candidate.bytes))
                                .foregroundStyle(highlight)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var marked: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Marked")
                .font(.headline)
            if model.marks.marks.isEmpty {
                Text("Nothing marked. Space marks the tile you point at.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.marks.marks.count) paths · \(humanBytes(model.marks.bytes))")
                ForEach(model.marks.marks.prefix(8)) { mark in
                    Text(URL(fileURLWithPath: mark.path).lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                }
            }
        }
    }

    private var disk: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Disk")
                .font(.headline)
            if let space = model.space {
                let projected = space.afterRemoving(model.marks.bytes)
                ProgressView(value: space.usedFraction)
                    .tint(highlight)
                Text("Free \(humanBytes(space.available))")
                Text("After marks \(humanBytes(projected.available))")
                    .foregroundStyle(highlight)
                if space.purgeable > 0 {
                    Text("macOS can free \(humanBytes(space.purgeable))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Volume space unread")
                    .foregroundStyle(.secondary)
            }
            if model.progress.errors > 0 {
                Button("\(model.progress.errors) unreadable") { model.openPrivacy() }
                    .font(.callout)
            }
        }
    }
}
