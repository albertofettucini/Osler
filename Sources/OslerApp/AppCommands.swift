import SwiftUI
import OslerEngine

extension Notification.Name {
    /// Cmd+, lives in a Commands block with no view environment — it posts
    /// this, and RootView (which has openWindow) opens the settings window.
    static let openOslerSettings = Notification.Name("openOslerSettings")
    /// Same trick for ⌘K: RootView owns the palette overlay.
    static let openOslerPalette = Notification.Name("openOslerPalette")
}

/// Menu-bar commands: File (new/open/save + templates), and Flow (run/stop).
struct AppCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var editor: FlowEditor
    @ObservedObject var run: RunController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updates: UpdateController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Osler") { AppInfo.showAboutPanel() }
            if updates.isAvailable {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheck)
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                NotificationCenter.default.post(name: .openOslerSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                // A focused text field keeps its own character-level undo;
                // the graph stack takes over everywhere else.
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView,
                   let manager = text.undoManager, manager.canUndo {
                    manager.undo()
                } else {
                    editor.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!editor.canUndo && !(NSApp.keyWindow?.firstResponder is NSTextView))

            Button("Redo") {
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView,
                   let manager = text.undoManager, manager.canRedo {
                    manager.redo()
                } else {
                    editor.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!editor.canRedo && !(NSApp.keyWindow?.firstResponder is NSTextView))
        }

        CommandGroup(replacing: .newItem) {
            Button("New Flow") {
                replaceDocument { editor.newFlow() }
            }
            .keyboardShortcut("n", modifiers: .command)

            Menu("New from Template") {
                ForEach(StarterTemplates.all) { template in
                    Button(template.name) {
                        replaceDocument { editor.loadGraph(template.make(settings.templateContext), url: nil) }
                    }
                }
            }

            Button("Open…") {
                // Panel first: cancelling it (or a failed load) must leave the
                // current document, run results, and screen untouched.
                guard let url = FilePanels.open() else { return }
                if editor.isDirty {
                    guard Alerts.confirmDiscard("The flow \"\(editor.graph.name)\" has unsaved changes.") else {
                        return
                    }
                }
                if editor.load(url) {
                    run.cancel()
                    run.reset()
                    appState.screen = .builder
                }
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { saveFlow() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { saveFlowAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Save as Template…") {
                guard let name = Alerts.prompt(
                    "Save as Template",
                    message: "The current flow joins My Templates in the library, ready to reuse.",
                    defaultValue: editor.graph.name
                ) else { return }
                do {
                    try UserTemplates.save(editor.graph, named: name)
                } catch {
                    Alerts.error("Couldn't save the template", error.localizedDescription)
                }
            }
        }

        CommandGroup(after: .sidebar) {
            Button("Command Palette") {
                NotificationCenter.default.post(name: .openOslerPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)

            Button(appState.showLibrary ? "Collapse Library" : "Expand Library") {
                appState.showLibrary.toggle()
            }
            .keyboardShortcut("1", modifiers: .command)
            Button(appState.showInspector ? "Hide Inspector" : "Show Inspector") {
                appState.showInspector.toggle()
            }
            .keyboardShortcut("2", modifiers: .command)
        }

        CommandMenu("Flow") {
            Button("Run") {
                // Land in the builder so the run is actually visible
                // (state chips, streaming output, and the Stop control).
                appState.screen = .builder
                run.run(editor.graph, registry: settings.makeRegistry(), mcpServers: settings.mcpServers)
            }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!editor.isRunnable
                          || run.isRunning
                          || !settings.missingProviders(for: editor.graph).isEmpty)
            Button("Stop") { run.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!run.isRunning)
        }
    }

    /// Every path that replaces the open document goes through here: confirm
    /// if there are unsaved changes, stop/clear any run that belongs to the
    /// old graph, and land the user in the builder.
    private func replaceDocument(_ perform: () -> Void) {
        if editor.isDirty {
            guard Alerts.confirmDiscard("The flow \"\(editor.graph.name)\" has unsaved changes.") else {
                return
            }
        }
        run.cancel()
        run.reset()
        perform()
        appState.screen = .builder
    }

    private func saveFlow() {
        if let url = editor.fileURL {
            editor.save(to: url)
        } else {
            saveFlowAs()
        }
    }

    private func saveFlowAs() {
        let suggested = (editor.fileURL?.deletingPathExtension().lastPathComponent ?? editor.graph.name) + ".oslerflow"
        if let url = FilePanels.save(suggestedName: suggested) {
            editor.save(to: url)
        }
    }
}
