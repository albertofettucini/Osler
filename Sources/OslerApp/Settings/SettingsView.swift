import SwiftUI
import OslerEngine

/// Settings, System Settings-style: a glass sidebar of categories on the
/// left, grouped row cards on the right. Sits on the same backdrop (base +
/// the user's wash) as the main window, so it reads as part of the app.
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var updates: UpdateController

    private enum Tab: String, CaseIterable {
        case general = "General"
        case appearance = "Appearance"
        case apiKeys = "API Keys"
        case mcp = "MCP"
    }

    @State private var tab: Tab = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.hairline)
            content
        }
        .background {
            ZStack {
                Theme.background
                if let tint = BackdropTint.by(id: settings.backdropTintID) {
                    tint.gradient.opacity(0.5)
                }
            }
            .ignoresSafeArea()
        }
        .navigationTitle("Settings")
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.oslerBody(15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.top, 40) // clears the traffic lights
                .padding(.bottom, 12)

            sideRow(.general, "slider.horizontal.3")
            sideRow(.appearance, "paintpalette")
            sideRow(.apiKeys, "key.fill")
            sideRow(.mcp, "wrench.and.screwdriver")

            Spacer()
        }
        .padding(8)
        .frame(width: 172)
        .background(Theme.panel)
        .background(.ultraThinMaterial)
    }

    private func sideRow(_ value: Tab, _ symbol: String) -> some View {
        let active = tab == value
        return Button {
            tab = value
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                Text(value.rawValue)
                    .font(.oslerBody(12.5, weight: active ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.hoverFill)
                .opacity(active ? 1 : 0))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(HoverRowStyle())
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch tab {
                case .general: general
                case .appearance: appearance
                case .apiKeys: keys
                case .mcp: mcp
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 508, height: 560)
    }

    /// Behaviour, not looks — so opening Settings doesn't greet you with a
    /// wall of colour.
    @ViewBuilder private var general: some View {
        groupCard {
            row("Double-click removes a node", "Turn this off if you delete cards by accident.") {
                Toggle("", isOn: $settings.doubleClickRemoves)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.accent)
            }
            if updates.isAvailable {
                rowDivider
                row("Check for updates automatically",
                    "Osler looks for a new version now and then. Updates are signature-verified.") {
                    Toggle("", isOn: Binding(
                        get: { updates.automaticallyChecks },
                        set: { updates.automaticallyChecks = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.accent)
                }
            }
            rowDivider
            row("Version", AppInfo.tagline) {
                HStack(spacing: 8) {
                    if updates.isAvailable {
                        Button("Check now") { updates.checkForUpdates() }
                            .buttonStyle(HoverPillStyle())
                            .font(.oslerBody(11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .disabled(!updates.canCheck)
                    }
                    Button("About") { AppInfo.showAboutPanel() }
                        .buttonStyle(HoverPillStyle())
                        .font(.oslerBody(11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private var appearance: some View {
        groupCard {
            row("Theme", "Follow the system, or force light / dark.") {
                Picker("", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 186)
            }
        }

        groupCard {
            tintSection("Background tint",
                        "One wash of personality under the glass.",
                        selection: $settings.backdropTintID)
        }

        groupCard {
            tintSection("Node card tint",
                        "Colours the cards on the canvas, gently enough to stay readable.",
                        selection: $settings.nodeTintID)
        }
    }

    /// Swatches in three labelled families rather than one long rainbow — the
    /// same colours, read as a palette instead of a paint box.
    private func tintSection(_ title: String, _ subtitle: String,
                             selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            rowLabel(title, subtitle)
            tintRow("NEUTRAL", BackdropTint.all(.paper), selection: selection, includesNone: true)
            tintRow("COLOUR", BackdropTint.all(.solid), selection: selection)
            tintRow("GRADIENT", BackdropTint.all(.gradient), selection: selection)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private func tintRow(_ label: String, _ tints: [BackdropTint],
                         selection: Binding<String>,
                         includesNone: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.oslerLabel(8.5, weight: .semibold))
                .kerning(1)
                .foregroundStyle(Theme.textFaint)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 27), spacing: 7)],
                      alignment: .leading, spacing: 8) {
                if includesNone {
                    TintDot(tint: nil, selected: selection.wrappedValue.isEmpty) {
                        selection.wrappedValue = ""
                    }
                }
                ForEach(tints) { tint in
                    TintDot(tint: tint, selected: selection.wrappedValue == tint.id) {
                        selection.wrappedValue = tint.id
                    }
                }
            }
        }
    }

    @ViewBuilder private var keys: some View {
        Text("Bring your own keys — stored in your Keychain as you type, used only to call each provider.")
            .font(.oslerBody(11.5))
            .foregroundStyle(Theme.textSecondary)

        groupCard {
            keyRow(title: "Anthropic",
                   placeholder: "sk-ant-…",
                   help: "console.anthropic.com",
                   text: $settings.anthropicKey,
                   isSet: settings.hasKey(for: .anthropic))
            rowDivider
            keyRow(title: "OpenAI",
                   placeholder: "sk-…",
                   help: "platform.openai.com",
                   text: $settings.openAIKey,
                   isSet: settings.hasKey(for: .openai))
            rowDivider
            ollamaRow
        }

        Label("No telemetry — nothing leaves your Mac except the API calls you run.",
              systemImage: "lock.shield")
            .font(.oslerBody(10.5))
            .foregroundStyle(Theme.textFaint)
    }

    // MARK: Building blocks

    private func groupCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline))
            .hoverHighlight()
    }

    private var rowDivider: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 14)
    }

    private func row<Control: View>(_ title: String, _ subtitle: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            rowLabel(title, subtitle)
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func rowLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.oslerBody(12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.oslerBody(10.5))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// MCP servers: local stdio commands agents can call tools from.
    @ViewBuilder private var mcp: some View {
        Text("Agents can call tools from MCP servers — files, web, APIs. Osler launches the command you give it and talks over stdio. Local commands only; nothing is installed for you.")
            .font(.oslerBody(11.5))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        groupCard {
            if settings.mcpServers.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.textFaint)
                    Text("No servers yet — add one below.")
                        .font(.oslerBody(11.5))
                        .foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                ForEach($settings.mcpServers) { $server in
                    if server.id != settings.mcpServers.first?.id { rowDivider }
                    mcpServerRow($server)
                }
            }
        }

        HStack {
            Button {
                settings.mcpServers.append(MCPServerConfig(name: "New Server", command: ""))
            } label: {
                Label("Add Server", systemImage: "plus")
                    .font(.oslerBody(11.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.surfaceContainer))
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .contentShape(Capsule())
            }
            .buttonStyle(HoverPillStyle())
            Spacer()
        }

        Text("Example: npx -y @modelcontextprotocol/server-filesystem ~/Documents\nThen enable the server on an Agent node (inspector → MCP tools).")
            .font(.oslerBody(10.5))
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func mcpServerRow(_ server: Binding<MCPServerConfig>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: server.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.accent)
                TextField("Name", text: server.name)
                    .textFieldStyle(.plain)
                    .font(.oslerBody(12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Test") { testServer(server.wrappedValue) }
                    .buttonStyle(HoverPillStyle())
                    .font(.oslerLabel(10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .help("Launch the server and list its tools")
                Button {
                    settings.mcpServers.removeAll { $0.id == server.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
                .help("Remove this server")
            }
            TextField("npx -y @modelcontextprotocol/server-filesystem ~/Documents",
                      text: server.command)
                .textFieldStyle(.plain)
                .font(.oslerLabel(11))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surfaceContainer))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func testServer(_ config: MCPServerConfig) {
        Task { @MainActor in
            do {
                let client = try MCPClient(command: config.command)
                try await client.initialize()
                let tools = try await client.listTools()
                await client.shutdown()
                if tools.isEmpty {
                    Alerts.info("\(config.name) connected", "The server answered, but reports no tools.")
                } else {
                    let names = tools.map(\.name).joined(separator: ", ")
                    Alerts.info("\(config.name) connected",
                                "\(tools.count) tool\(tools.count == 1 ? "" : "s"): \(names)")
                }
            } catch {
                Alerts.error("Couldn't reach \(config.name)", String(describing: error))
            }
        }
    }

    /// Ollama runs locally — a server URL instead of a key.
    private var ollamaRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Ollama")
                    .font(.oslerBody(12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("LOCAL")
                    .font(.oslerLabel(8.5, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceContainerHigh))
                Spacer()
                Text("no key — runs on this Mac")
                    .font(.oslerBody(10))
                    .foregroundStyle(Theme.textFaint)
            }
            TextField(OllamaProvider.defaultBaseURL, text: $settings.ollamaBaseURL)
                .textFieldStyle(.plain)
                .font(.oslerLabel(11.5))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surfaceContainer))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func keyRow(title: String, placeholder: String, help: String,
                        text: Binding<String>, isSet: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.oslerBody(12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if isSet {
                    Text("ACTIVE")
                        .font(.oslerLabel(8.5, weight: .semibold))
                        .kerning(1)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceContainerHigh))
                }
                Spacer()
                Text(help)
                    .font(.oslerBody(10))
                    .foregroundStyle(Theme.textFaint)
            }
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.oslerLabel(11.5))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surfaceContainer))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// One swatch in the Council-style backdrop picker. nil tint = no wash (pure
/// glass), drawn as a crossed-out circle like Council's "none" swatch.
/// Two-colour tints render as their diagonal gradient.
private struct TintDot: View {
    let tint: BackdropTint?
    let selected: Bool
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            ZStack {
                if let tint {
                    Circle().fill(tint.gradient)
                        .overlay(Circle().strokeBorder(Theme.hairline))
                } else {
                    Circle()
                        .strokeBorder(Theme.textSecondary, lineWidth: 1.6)
                        .overlay(
                            Rectangle()
                                .fill(Theme.textSecondary)
                                .frame(width: 1.6, height: 26)
                                .rotationEffect(.degrees(45))
                                .clipShape(Circle().inset(by: 2))
                        )
                }
            }
            .frame(width: 19, height: 19)
            .overlay(
                Circle()
                    .strokeBorder(selected ? Theme.textPrimary : .clear, lineWidth: 2)
                    .padding(-3.5)
            )
            .scaleEffect(hovering ? 1.15 : 1)
            .contentShape(Circle().inset(by: -5))
        }
        .buttonStyle(.plain)
        .help(tint?.name ?? "None (pure glass)")
        .onHover { inside in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hovering = inside }
        }
    }
}

/// The app-wide hover treatment for cards: Theme.hoverFill is a soft white
/// glow on dark and a gentle darken on light. Overlaid so it reads on top of
/// the card fill; hit-test transparent so it never eats clicks.
private struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 10
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.hoverFill)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(false)
            )
            // Containers glow but don't grow — scale is for controls.
            .shadow(color: Theme.textPrimary.opacity(hovering ? 0.09 : 0),
                    radius: hovering ? 10 : 0)
            .onHover { inside in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { hovering = inside }
            }
    }
}

extension View {
    fileprivate func hoverHighlight(cornerRadius: CGFloat = 10) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}
