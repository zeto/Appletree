import AppletreeCore
import SwiftUI

struct BreadcrumbBar: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(model.trail().enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button(item.title) { model.openCrumb(item) }
                        .buttonStyle(.plain)
                        .foregroundStyle(item.dim ? .secondary : .primary)
                    if let crumbs = item.crumbs, let tree = model.tree, let node = tree.resolve(crumbs), !node.children.isEmpty {
                        Menu {
                            ForEach(model.siblings(of: crumbs), id: \.0) { childIndex, child in
                                Button {
                                    model.jump(parent: crumbs, child: childIndex)
                                } label: {
                                    Text("\(child.name)  \(Int(share(part: child.bytes, total: max(node.bytes, 1))))%  \(humanBytes(child.value(model.options.metric)))")
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
