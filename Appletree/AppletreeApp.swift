import SwiftUI

@main
struct AppletreeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ExplorerView(model: model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.openFolder() }
                    .keyboardShortcut("o")
                Button("Scan Home") { model.scanHome() }
                Button("Scan Startup Disk") { model.scanStartupDisk() }
                Divider()
                Button("Scan Again") { model.rescan() }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .toolbar) {
                Button("Review Marks") { model.openReview() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Show Keys") { model.showHelp.toggle() }
                    .keyboardShortcut("?", modifiers: [.command])
            }
        }
    }
}
