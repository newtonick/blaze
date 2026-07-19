import SwiftUI

@main
struct BlazeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onAppear { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") { model.showImporter = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Rescan Cards") { Task { await model.rescanDisks() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
