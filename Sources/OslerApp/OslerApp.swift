import SwiftUI
import AppKit

@main
struct OslerMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var editor = FlowEditor()
    @StateObject private var settings = SettingsStore()
    @StateObject private var run = RunController()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(editor)
                .environmentObject(settings)
                .environmentObject(run)
                .frame(minWidth: 1080, minHeight: 680)
        }
        // No separate title bar: content reaches the top edge and the traffic
        // lights float over the app's own top bar.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 880)
        .commands {
            AppCommands(appState: appState, editor: editor, run: run,
                        settings: settings, updates: updates)
        }

        // A plain Window instead of the Settings scene: the Settings scene
        // refuses .hiddenTitleBar (it kept a black strip), a Window honours it.
        // Cmd+, still works via the replaced appSettings command.
        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(updates)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// Running as a Swift Package executable, the process launches without a bundle
/// activation policy — nudge it to a regular, foregrounded app so the window
/// appears and takes focus. Also the last line of defence for unsaved work:
/// closing the window or quitting routes through `applicationShouldTerminate`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by RootView on appear so the quit guard can see the document.
    static weak var editor: FlowEditor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let editor = Self.editor, editor.isDirty else { return .terminateNow }
            if Alerts.confirmDiscard("The flow \"\(editor.graph.name)\" has unsaved changes.") {
                return .terminateNow
            }
            // If quit was triggered by closing the last window, bring it back.
            NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
    }
}
