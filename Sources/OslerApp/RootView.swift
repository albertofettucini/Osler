import SwiftUI
import OslerEngine

/// The main window: a shared top bar over either the start screen or the
/// builder (library | canvas | inspector).
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var editor: FlowEditor
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var run: RunController

    /// Full screen slims the library down to its icon-only rail; the windowed
    /// preference is parked here and restored on exit.
    @State private var isFullscreen = false
    @State private var libraryBeforeFullscreen: Bool?
    @State private var showPalette = false

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider().overlay(Theme.hairline)
            screenContent
        }
        // The base backdrop plus the user's one wash of personality (§6):
        // chrome is grayscale, so any tint under the glass works.
        .background {
            ZStack {
                Theme.background
                if let tint = BackdropTint.by(id: settings.backdropTintID) {
                    tint.gradient.opacity(0.5)
                }
            }
            .ignoresSafeArea()
        }
        .background(WindowConfigurator())
        // Full screen opens with the library collapsed to its rail (the point
        // of full screen is canvas), but the edge handle must still work in
        // there — so it collapses the real preference and restores it on exit
        // rather than pinning the panel to the rail.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullscreen = true
            libraryBeforeFullscreen = appState.showLibrary
            appState.showLibrary = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullscreen = false
            if let previous = libraryBeforeFullscreen { appState.showLibrary = previous }
            libraryBeforeFullscreen = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .openOslerSettings)) { _ in
            openWindow(id: "settings")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openOslerPalette)) { _ in
            showPalette.toggle()
        }
        .overlay {
            if showPalette {
                CommandPalette(items: paletteItems) { showPalette = false }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: showPalette)
        .onAppear {
            AppDelegate.editor = editor
            settings.applyAppearance()
            restoreLastFlowIfFresh()
        }
    }

    /// Reopens the most recent flow on a fresh launch, so the app comes back
    /// the way it was left. With no history — a brand-new user — reseeds the
    /// starter flow for THIS user, so it points at a provider they can
    /// actually run (local Ollama when no key is set) instead of a dead Run
    /// button. FlowEditor is built before SettingsStore is readable, which is
    /// why the seed happens here rather than in its initialiser.
    @State private var didRestore = false
    private func restoreLastFlowIfFresh() {
        guard !didRestore else { return }
        didRestore = true
        guard editor.fileURL == nil, !editor.isDirty else { return }
        if let last = RecentFlows.entries().first {
            _ = editor.load(last.url)
        } else {
            editor.loadGraph(StarterTemplates.all[0].make(settings.templateContext), url: nil)
        }
    }

    /// Everything ⌘K can do.
    private var paletteItems: [PaletteItem] {
        var items: [PaletteItem] = []

        for (kind, subtitle) in [(NodeKind.input, "Starting text you type"),
                                 (.agent, "Calls an LLM with a prompt"),
                                 (.condition, "Routes to a yes/no branch"),
                                 (.output, "Shows the final text")] {
            items.append(PaletteItem(
                title: "Add \(Node.defaultName(for: kind)) node",
                subtitle: subtitle,
                symbol: Theme.nodeGlyph(kind),
                keywords: "add insert new node \(kind.rawValue)"
            ) {
                appState.screen = .builder
                let step = CGFloat(editor.graph.nodes.count % 6) * 28
                editor.addNode(kind, at: editor.screenToWorld(CGPoint(x: 320 + step, y: 220 + step)))
            })
        }

        for template in StarterTemplates.all {
            items.append(PaletteItem(
                title: "Template: \(template.name)",
                subtitle: template.summary,
                symbol: "square.grid.2x2",
                keywords: "template starter \(template.name)"
            ) {
                guard !editor.isDirty
                    || Alerts.confirmDiscard("The flow \"\(editor.graph.name)\" has unsaved changes.") else { return }
                run.cancel()
                run.reset()
                editor.loadGraph(template.make(settings.templateContext), url: nil)
                appState.screen = .builder
            })
        }

        items.append(PaletteItem(
            title: "New Flow", subtitle: "Start a blank canvas",
            symbol: "plus", keywords: "new blank flow create"
        ) {
            guard !editor.isDirty
                || Alerts.confirmDiscard("The flow \"\(editor.graph.name)\" has unsaved changes.") else { return }
            run.cancel()
            run.reset()
            editor.newFlow()
            appState.screen = .builder
        })

        if run.isRunning {
            items.append(PaletteItem(
                title: "Stop", subtitle: "Cancel the current run",
                symbol: "stop.fill", keywords: "stop cancel halt"
            ) { run.cancel() })
        } else {
            items.append(PaletteItem(
                title: "Run Flow", subtitle: "Execute the open flow (⌘R)",
                symbol: "play.fill", keywords: "run execute start"
            ) {
                appState.screen = .builder
                run.run(editor.graph, registry: settings.makeRegistry(), mcpServers: settings.mcpServers)
            })
        }

        items.append(PaletteItem(
            title: appState.showLibrary ? "Collapse Library" : "Expand Library",
            subtitle: "Toggle the left panel (⌘1)",
            symbol: "sidebar.leading", keywords: "library panel sidebar toggle collapse"
        ) { appState.showLibrary.toggle() })

        items.append(PaletteItem(
            title: appState.showInspector ? "Hide Inspector" : "Show Inspector",
            subtitle: "Toggle the right panel (⌘2)",
            symbol: "sidebar.trailing", keywords: "inspector panel sidebar toggle"
        ) { appState.showInspector.toggle() })

        items.append(PaletteItem(
            title: "Settings", subtitle: "Appearance, tints, and API keys (⌘,)",
            symbol: "gearshape", keywords: "settings preferences keys appearance tint"
        ) { openWindow(id: "settings") })

        items.append(PaletteItem(
            title: "Toggle Full Screen", subtitle: "Give the canvas the whole display",
            symbol: "arrow.up.left.and.arrow.down.right", keywords: "fullscreen full screen"
        ) { (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil) })

        return items
    }

    @ViewBuilder private var screenContent: some View {
        Group {
            switch appState.screen {
            case .home:
                HomeView()
            case .builder:
                HStack(spacing: 0) {
                    // Collapsing never removes the library — it slims to the
                    // icon rail, so nodes stay one click away.
                    LibraryPanel(compact: !appState.showLibrary)
                    Divider().overlay(Theme.outlineVariant.opacity(0.3))
                    CanvasView()
                        .overlay(alignment: .leading) {
                            PanelEdgeHandle(pointsLeft: appState.showLibrary) {
                                appState.showLibrary.toggle()
                            }
                            .help(appState.showLibrary ? "Collapse the library to icons (⌘1)"
                                                       : "Expand the node library (⌘1)")
                        }
                        .overlay(alignment: .trailing) {
                            PanelEdgeHandle(pointsLeft: !appState.showInspector) {
                                appState.showInspector.toggle()
                            }
                            .help(appState.showInspector ? "Hide the inspector (⌘2)"
                                                         : "Show the inspector (⌘2)")
                        }
                    if appState.showInspector {
                        Divider().overlay(Theme.outlineVariant.opacity(0.3))
                        InspectorView().frame(width: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: appState.showLibrary)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: appState.showInspector)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isFullscreen)
            }
        }
    }
}

/// Grabs the hosting NSWindow and makes it behave like a full-fledged Mac app
/// window: full-screen capable (green button) and frame-remembering. Launched
/// as an SPM executable, the window misses the bundle plumbing that normally
/// grants both.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView { ConfiguratorView() }
    func updateNSView(_ nsView: ConfiguratorView, context: Context) {}

    final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.setFrameAutosaveName("OslerMainWindow")
        }
    }
}

/// Frosted top bar: wordmark, Workflows/Builder tabs, run controls, settings.
struct TopBar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var editor: FlowEditor
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var run: RunController
    @Environment(\.openWindow) private var openWindow

    private var missingProviders: [ProviderID] {
        settings.missingProviders(for: editor.graph)
    }

    private var canRun: Bool {
        editor.isRunnable && missingProviders.isEmpty && !run.isRunning
    }

    var body: some View {
        HStack(spacing: 22) {
            navTab("Workflows", screen: .home)
            navTab("Builder", screen: .builder)

            Spacer()

            if appState.screen == .builder {
                providerStatus

                if run.isRunning {
                    Button { run.cancel() } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.oslerBody(12, weight: .semibold))
                    }
                    .buttonStyle(PillButtonStyle(tint: Theme.stateColor(.failed)))
                } else {
                    Button { run.run(editor.graph, registry: settings.makeRegistry(), mcpServers: settings.mcpServers) } label: {
                        Label("Run", systemImage: "play.fill")
                            .font(.oslerBody(12, weight: .semibold))
                    }
                    .buttonStyle(PillButtonStyle(tint: Theme.accent))
                    .disabled(!canRun)
                    .help(runHelp)
                }
            }

            Button { openWindow(id: "settings") } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(HoverRowStyle())
            .help("API keys & settings")
        }
        // Extra leading room clears the traffic lights, which float over this
        // bar now that the window has no separate title bar.
        .padding(.leading, 84)
        .padding(.trailing, 20)
        .frame(height: 56)
        .background(Theme.panel)
        .background(.ultraThinMaterial)
    }

    private func navTab(_ title: String, screen: AppScreen) -> some View {
        NavTab(title: title, isActive: appState.screen == screen) {
            appState.screen = screen
        }
    }


    @ViewBuilder private var providerStatus: some View {
        if !missingProviders.isEmpty {
            Button { openWindow(id: "settings") } label: {
                Label("Add \(missingProviders.map(\.displayName).joined(separator: " & ")) key",
                      systemImage: "key.slash")
                    .font(.oslerLabel(11))
                    .foregroundStyle(Theme.stateColor(.failed))
            }
            .buttonStyle(.plain)
        } else if !settings.configuredProviders.isEmpty {
            Label("\(settings.configuredProviders.map(\.displayName).joined(separator: ", ")) ready",
                  systemImage: "key.fill")
                .font(.oslerLabel(11))
                .foregroundStyle(Theme.textFaint)
        }
    }

    private var runHelp: String {
        if let issue = editor.validationIssues.first { return issue.description }
        if !missingProviders.isEmpty { return "Add an API key to run." }
        return "Run the flow"
    }
}

/// The minimal panel toggle: a slim handle riding the panel edge, vertically
/// centered. Idle it's a quiet 4pt bar; on hover it becomes a chevron tab.
private struct PanelEdgeHandle: View {
    let pointsLeft: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.panelRaised)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.hairline))
                    .opacity(hovering ? 1 : 0)
                Capsule()
                    .fill(Theme.outlineVariant.opacity(0.8))
                    .frame(width: 4, height: 40)
                    .opacity(hovering ? 0 : 1)
                Image(systemName: pointsLeft ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .opacity(hovering ? 1 : 0)
            }
            .frame(width: 16, height: 56)
            .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.13)) { hovering = inside }
        }
    }
}

/// A top-bar tab with the standard hover treatment (darken on light, glow on
/// dark) as a pill around the label, and an underline when active.
private struct NavTab: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Spacer()
                Text(title)
                    .font(.oslerBody(13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                Rectangle()
                    .fill(isActive ? Theme.textPrimary : .clear)
                    .frame(height: 2)
                    .cornerRadius(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .fixedSize()
            // Holistic hover, like the start-screen cards: the whole tab cell
            // lights up, grows a touch, and glows neutrally.
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.hoverFill)
                    .opacity(hovering ? 1 : 0)
                    .padding(.vertical, 7)
            )
            .scaleEffect(hovering ? 1.02 : 1)
            .shadow(color: Theme.textPrimary.opacity(hovering ? 0.10 : 0),
                    radius: hovering ? 8 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) { hovering = inside }
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? .white : Theme.textFaint)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(isEnabled ? tint : Theme.surfaceContainerHigh))
            .scaleEffect(configuration.isPressed ? 0.97 : hovering && isEnabled ? 1.05 : 1)
            .shadow(color: isEnabled ? tint.opacity(hovering ? 0.5 : 0.3) : .clear,
                    radius: hovering ? 9 : 5, y: 2)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: hovering)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
