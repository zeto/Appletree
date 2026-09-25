import AppletreeCore
import SwiftUI

struct ReviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        let removal = model.removalPlan
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Review")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Back") { model.screen = .explore }
                    .keyboardShortcut(.cancelAction)
            }
            Text(removal.targets.isEmpty
                ? "Nothing will be removed."
                : "\(removal.targets.count) to remove · \(humanBytes(removal.bytes))")
                .font(.title3)
                .foregroundStyle(highlight)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if removal.targets.isEmpty && removal.blocked.isEmpty {
                        Text("Mark a folder or file in the map, then come back here. Space marks the selected tile. Nothing is deleted from this screen until you choose Trash or Delete Permanently.")
                            .foregroundStyle(.secondary)
                    }
                    if !removal.targets.isEmpty {
                        Text("Will go")
                            .font(.headline)
                        ForEach(removal.targets) { target in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: target.path).lastPathComponent)
                                    Text(target.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(humanBytes(target.bytes))
                                    .monospacedDigit()
                                Button("Unmark") { model.marks.remove(target.path) }
                            }
                        }
                    }
                    if !removal.absorbed.isEmpty {
                        Text("Inside a marked folder")
                            .font(.headline)
                        ForEach(removal.absorbed) { target in
                            Text(target.path)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if !removal.blocked.isEmpty {
                        Text("Refused")
                            .font(.headline)
                        ForEach(removal.blocked) { blocked in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(blocked.path).lineLimit(1).truncationMode(.middle)
                                Text(blocked.reason)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Move to Trash") { model.commit(mode: .trash) }
                    .buttonStyle(.borderedProminent)
                    .tint(highlight)
                    .disabled(removal.targets.isEmpty || model.removing)
                    .keyboardShortcut(.defaultAction)
                Button("Delete Permanently") { model.commit(mode: .permanent) }
                    .disabled(removal.targets.isEmpty || model.removing)
                if model.removing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Unmark All") { model.marks.removeAll() }
                    .disabled(model.marks.marks.isEmpty)
            }
            Text("Trash can be recovered until you empty it. Permanent deletion asks again and names what goes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Delete permanently?", isPresented: $model.confirmingPermanent) {
            Button("Delete", role: .destructive) { model.commit(mode: .permanent) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.permanentMessage)
        }
    }
}
