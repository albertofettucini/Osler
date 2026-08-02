import SwiftUI
import OslerEngine

/// The builder's left sidebar: the node library (click to add), starter
/// templates, and a settings shortcut — every row does something real.
struct LibraryPanel: View {
    /// Full screen shows the icon-only rail; windowed shows the full panel.
    var compact = false

    @EnvironmentObject var editor: FlowEditor
    @EnvironmentObject var run: RunController
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    @State private var userTemplates: [UserTemplates.Entry] = []

    private static let nodeKinds: [(NodeKind, String)] = [
        (.input, "Starting text you type"),
        (.agent, "Calls an LLM with a prompt"),
        (.condition, "Routes to a yes/no branch"),
        (.output, "Shows the final text"),
    ]

    var body: some View {
        Group {
            if compact {
                compactBody.padding(10).frame(width: 60)
            } else {
                fullBody.padding(14).frame(width: 236)
            }
        }
        .background(Theme.panel)
        .background(.ultraThinMaterial)
        .onAppear { userTemplates = UserTemplates.all() }
        .onReceive(NotificationCenter.default.publisher(for: UserTemplates.changed)) { _ in
            userTemplates = UserTemplates.all()
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 22)

            // 4 node types + 8 templates + user templates outgrow short
            // windows — the sections scroll, header and Settings stay put.
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("NODES")
                    VStack(spacing: 2) {
                        ForEach(Self.nodeKinds, id: \.0) { kind, subtitle in
                            nodeRow(kind, subtitle)
                        }
                    }
                    Text("Four nodes. That's the point.")
                        .font(.oslerBody(10))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 22)

                    sectionLabel("TEMPLATES")
                    VStack(spacing: 2) {
                        ForEach(StarterTemplates.all) { template in
                            templateRow(template)
                        }
                    }

                    if !userTemplates.isEmpty {
                        sectionLabel("MY TEMPLATES")
                            .padding(.top, 22)
                        VStack(spacing: 2) {
                            ForEach(userTemplates) { entry in
                                userTemplateRow(entry)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            Divider().overlay(Theme.hairline)
            Button { openWindow(id: "settings") } label: {
                Label {
                    Text("Settings").font(.oslerLabel(12))
                } icon: {
                    Image(systemName: "gearshape").font(.system(size: 13))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverRowStyle())
            .padding(.top, 8)
        }
    }

    /// Icon-only rail for full screen: same actions (click to add, drag onto
    /// the canvas), names live in the tooltips.
    private var compactBody: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surfaceContainer)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary))
                .padding(.top, 4)
                .padding(.bottom, 10)

            ForEach(Self.nodeKinds, id: \.0) { kind, subtitle in
                Button {
                    addCascaded(kind)
                } label: {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.nodeTint(kind).opacity(0.12))
                        .frame(width: 34, height: 34)
                        .overlay(Image(systemName: Theme.nodeGlyph(kind))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.nodeTint(kind)))
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
                .help("\(Node.defaultName(for: kind)) — \(subtitle)")
                .onDrag { NSItemProvider(object: (Self.dragPrefix + kind.rawValue) as NSString) }
            }

            Divider().overlay(Theme.hairline).padding(.vertical, 8)

            ForEach(StarterTemplates.all) { template in
                Button { loadTemplate(template) } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 40, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
                .help("Template: \(template.name) — \(template.summary)")
            }

            Spacer()

            Button { openWindow(id: "settings") } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverRowStyle())
            .help("Settings")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surfaceContainer)
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary))
            VStack(alignment: .leading, spacing: 1) {
                Text("Node Library")
                    .font(.oslerBody(14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Click or drag onto the canvas")
                    .font(.oslerLabel(10))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 4).padding(.top, 6)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.oslerLabel(10, weight: .semibold))
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 12).padding(.bottom, 6)
    }

    /// Payload prefix for dragging a node kind onto the canvas.
    static let dragPrefix = "osler-node:"

    /// Cascade successive inserts so repeat clicks never stack cards invisibly
    /// on the exact same spot.
    private func addCascaded(_ kind: NodeKind) {
        let step = CGFloat(editor.graph.nodes.count % 6) * 28
        editor.addNode(kind, at: editor.screenToWorld(CGPoint(x: 280 + step, y: 180 + step)))
    }

    private func nodeRow(_ kind: NodeKind, _ subtitle: String) -> some View {
        Button {
            addCascaded(kind)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.nodeTint(kind).opacity(0.12))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: Theme.nodeGlyph(kind))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.nodeTint(kind)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(Node.defaultName(for: kind))
                        .font(.oslerBody(12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.oslerBody(10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.outlineVariant)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .onDrag { NSItemProvider(object: (Self.dragPrefix + kind.rawValue) as NSString) }
    }

    private func userTemplateRow(_ entry: UserTemplates.Entry) -> some View {
        Button {
            guard !editor.isDirty
                || Alerts.confirmDiscard("The flow \"\(editor.graph.name)\" has unsaved changes.") else {
                return
            }
            do {
                let graph = try FlowGraph(contentsOf: entry.url)
                run.cancel()
                run.reset()
                // url: nil — Save must never overwrite the template itself.
                editor.loadGraph(graph, url: nil)
            } catch {
                Alerts.error("Couldn't open \"\(entry.name)\"", error.localizedDescription)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bookmark")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28)
                Text(entry.name)
                    .font(.oslerBody(12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .contextMenu {
            Button(role: .destructive) {
                UserTemplates.delete(entry)
            } label: {
                Label("Delete Template", systemImage: "trash")
            }
        }
    }

    private func loadTemplate(_ template: StarterTemplate) {
        guard !editor.isDirty
            || Alerts.confirmDiscard("The flow \"\(editor.graph.name)\" has unsaved changes.") else {
            return
        }
        run.cancel()
        run.reset()
        editor.loadGraph(template.make(settings.templateContext), url: nil)
    }

    private func templateRow(_ template: StarterTemplate) -> some View {
        Button {
            loadTemplate(template)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(template.name)
                        .font(.oslerBody(12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(template.summary)
                        .font(.oslerBody(10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

/// The app-wide hover feel: the control fills (Theme.hoverFill), grows a
/// touch, and glows neutrally — dark halo on light, white glow on dark. A
/// press sinks it softly with a spring.
struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.hoverFill)
                    .opacity(hovering ? 1 : 0)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : hovering ? 1.02 : 1)
            .shadow(color: Theme.textPrimary.opacity(hovering ? 0.12 : 0),
                    radius: hovering ? 7 : 0)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: hovering)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
