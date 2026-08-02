import SwiftUI
import OslerEngine

/// The node canvas: a pan/zoom viewport over a large world in which nodes live.
/// Empty space pans; nodes drag; output ports wire. Built from scratch — no
/// external node-editor library.
struct CanvasView: View {
    @EnvironmentObject var editor: FlowEditor
    @EnvironmentObject var run: RunController
    @EnvironmentObject var settings: SettingsStore

    private let worldSize = CGSize(width: 6000, height: 4000)
    @State private var panStart: CGSize?
    @State private var lastMagnification: CGFloat = 1
    @State private var quickAdd: QuickAddRequest?
    /// Shift+drag rubber-band selection, in canvas space.
    @State private var marqueeStart: CGPoint?
    @State private var marqueeRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Background: catches pans and taps-to-deselect. The scroll
                // catcher underneath makes two-finger trackpad scrolling pan
                // the canvas.
                Rectangle()
                    .fill(Theme.canvas)
                    .background(ScrollPanCatcher(
                        onScroll: { delta in
                            editor.offset = CGSize(
                                width: editor.offset.width + delta.width,
                                height: editor.offset.height + delta.height
                            )
                        },
                        onMouseDown: { point, modifiers in
                            // Instant selection at mouse-down: pure observation,
                            // so it can never starve the drag/tap gestures.
                            let world = editor.screenToWorld(point)
                            guard let hit = editor.graph.nodes.last(where: {
                                NodeGeometry.rect($0).insetBy(dx: -10, dy: -10).contains(world)
                            }) else { return }
                            if modifiers.contains(.shift) {
                                editor.toggleSelection(hit.id)
                            } else if !editor.selectedIDs.contains(hit.id) {
                                // Pressing a member of a multi-selection keeps
                                // the group (so it can be dragged together).
                                editor.selectedIDs = [hit.id]
                            }
                        }
                    ))
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    // Double-click first so it wins; the single tap (wire
                    // delete / deselect) fires only after a double is ruled out.
                    .onTapGesture(count: 2, coordinateSpace: .named("canvas")) { location in
                        quickAdd = QuickAddRequest(point: location)
                    }
                    .onTapGesture(coordinateSpace: .named("canvas")) { location in
                        handleCanvasTap(at: location)
                    }

                GridBackground(scale: editor.scale, offset: editor.offset)
                    .allowsHitTesting(false)

                worldContainer
                    .frame(width: worldSize.width, height: worldSize.height, alignment: .topLeading)
                    .scaleEffect(editor.scale, anchor: .topLeading)
                    .offset(editor.offset)

                // Shift+drag rubber band.
                if let rect = marqueeRect {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.hoverFill)
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Theme.textPrimary.opacity(0.35), lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
            // Pin the stack to the viewport: the world container's fixed frame
            // would otherwise inflate the ZStack to 6000×4000 (scaleEffect and
            // offset are render-only), pushing the bottom-aligned overlays
            // ~4000pt below the visible area and making .clipped() a no-op.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            // All gestures measure in this UNTRANSFORMED space. scaleEffect/offset
            // are render transforms that coordinate-space conversion does not undo,
            // so a named space inside them would report misleading locations at
            // scale != 1. Instead: gestures read screen points here, and
            // FlowEditor.screenToWorld converts explicitly.
            .coordinateSpace(name: "canvas")
            // Pinch-zoom lives on the whole canvas (an ancestor of the nodes),
            // so it works no matter what the pointer is over.
            .simultaneousGesture(magnifyGesture(viewSize: geo.size))
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 10) {
                    // Informational only — never allowed to swallow clicks.
                    statusBadge
                        .frame(maxWidth: 440, alignment: .trailing)
                        .allowsHitTesting(false)
                    fullscreenControl
                }
                .padding(16)
            }
            .overlay {
                if editor.graph.nodes.isEmpty {
                    emptyState
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: editor.graph.nodes.isEmpty)
            // Anchor for the double-click quick-add popover, parked at the
            // clicked point. Hit-test transparent — it's pure geometry.
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .offset(x: quickAdd?.point.x ?? 0, y: quickAdd?.point.y ?? 0)
                    .allowsHitTesting(false)
                    .popover(item: $quickAdd, arrowEdge: .bottom) { request in
                        QuickAddMenu { kind in
                            addNode(kind, centeredAt: request.point)
                            quickAdd = nil
                        }
                    }
            }
            // Library rows drag in as "osler-node:<kind>" strings; drop lands
            // the card centered under the cursor.
            .onDrop(of: [.plainText], isTargeted: nil) { providers, location in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let raw = object as? String,
                          raw.hasPrefix(LibraryPanel.dragPrefix),
                          let kind = NodeKind(rawValue: String(raw.dropFirst(LibraryPanel.dragPrefix.count)))
                    else { return }
                    Task { @MainActor in
                        addNode(kind, centeredAt: location)
                    }
                }
                return true
            }
            .clipped()
            .focusable()
            .focusEffectDisabled() // no blue system focus ring around the canvas
            .onDeleteCommand { editor.deleteSelection() }
            .onAppear {
                // Fit once per document (flag lives on FlowEditor) — returning
                // from the Workflows tab keeps the user's pan/zoom.
                if editor.needsInitialFit, fitToContent(viewSize: geo.size) {
                    editor.needsInitialFit = false
                }
            }
            .onChange(of: editor.fitToken) { _, _ in
                editor.needsInitialFit = !fitToContent(viewSize: geo.size)
            }
            // The viewport can arrive (or grow) after the fit was requested —
            // entering full screen, or a window that was still laying out.
            .onChange(of: geo.size) { _, size in
                if editor.needsInitialFit, fitToContent(viewSize: size) {
                    editor.needsInitialFit = false
                }
            }
        }
    }

    private var worldContainer: some View {
        ZStack(alignment: .topLeading) {
            WiresLayer()
            ForEach(editor.graph.nodes) { node in
                NodeView(node: node)
                    // The birth "pop" — only plays when the insertion itself
                    // is animated (FlowEditor.addNode wraps it); a plain load
                    // just draws the card.
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }

    /// Adds a node with its card centered on the given canvas-space point.
    private func addNode(_ kind: NodeKind, centeredAt screenPoint: CGPoint) {
        let world = editor.screenToWorld(screenPoint)
        editor.addNode(kind, at: CGPoint(x: world.x - NodeGeometry.width / 2,
                                         y: world.y - NodeGeometry.height / 2))
    }

    // MARK: Empty state

    /// A friendly invitation instead of a silent void. Sits over the canvas;
    /// only its own cards block clicks, the rest of the viewport still pans.
    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Theme.surfaceContainer).frame(width: 64, height: 64)
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 5) {
                Text("A blank canvas")
                    .font(.oslerBody(16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Double-click anywhere to add a node,\nor drag one in from the library.")
                    .font(.oslerBody(12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            HStack(spacing: 8) {
                ForEach(StarterTemplates.all) { template in
                    Button {
                        loadTemplate(template)
                    } label: {
                        Label(template.name, systemImage: "square.grid.2x2")
                            .font(.oslerBody(11.5, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(Capsule().fill(Theme.panelRaised))
                            .overlay(Capsule().strokeBorder(Theme.cardBorder))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(HoverPillStyle())
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: 340)
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

    // MARK: Wire removal

    /// A click on a wire removes it directly; a click on empty canvas clears
    /// the node selection.
    private func handleCanvasTap(at screenPoint: CGPoint) {
        let world = editor.screenToWorld(screenPoint)
        if let edgeID = edgeHit(at: world) {
            editor.disconnect(edgeID)
        } else {
            editor.selection = nil
        }
    }

    /// The wire nearest to a world point, within a constant screen-feel
    /// tolerance — or nil when the tap is on empty canvas.
    private func edgeHit(at point: CGPoint) -> UUID? {
        let tolerance = max(8, 10 / editor.scale)
        let nodesByID = Dictionary(editor.graph.nodes.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var best: (id: UUID, distance: CGFloat)?
        for edge in editor.graph.edges {
            guard let from = nodesByID[edge.from], let to = nodesByID[edge.to],
                  let start = NodeGeometry.outputPortPoint(from, port: edge.fromPort) else { continue }
            let end = NodeGeometry.inputPortPoint(to)
            for step in 0...24 {
                let sample = NodeGeometry.wirePoint(CGFloat(step) / 24, from: start, to: end)
                let distance = hypot(sample.x - point.x, sample.y - point.y)
                if distance < tolerance && (best == nil || distance < best!.distance) {
                    best = (edge.id, distance)
                }
            }
        }
        return best?.id
    }

    // MARK: Gestures

    private var panGesture: some Gesture {
        DragGesture(coordinateSpace: .named("canvas"))
            .onChanged { value in
                if panStart == nil, marqueeStart == nil {
                    if NSEvent.modifierFlags.contains(.shift) {
                        marqueeStart = value.startLocation
                    } else {
                        panStart = editor.offset
                    }
                }
                if let start = marqueeStart {
                    let rect = CGRect(x: min(start.x, value.location.x),
                                      y: min(start.y, value.location.y),
                                      width: abs(value.location.x - start.x),
                                      height: abs(value.location.y - start.y))
                    marqueeRect = rect
                    selectMarquee(rect)
                } else if let start = panStart {
                    editor.offset = CGSize(width: start.width + value.translation.width,
                                           height: start.height + value.translation.height)
                }
            }
            .onEnded { _ in
                panStart = nil
                marqueeStart = nil
                marqueeRect = nil
            }
    }

    /// Live rubber-band selection: everything intersecting the box.
    private func selectMarquee(_ rect: CGRect) {
        let a = editor.screenToWorld(rect.origin)
        let b = editor.screenToWorld(CGPoint(x: rect.maxX, y: rect.maxY))
        let world = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y))
        editor.selectedIDs = Set(
            editor.graph.nodes.filter { NodeGeometry.rect($0).intersects(world) }.map(\.id)
        )
    }

    private func magnifyGesture(viewSize: CGSize) -> some Gesture {
        // `value` is cumulative since the gesture began; dividing by the last
        // value yields the true per-event factor, so total zoom follows pinch
        // distance rather than gesture duration or trackpad event rate.
        MagnificationGesture()
            .onChanged { value in
                let anchor = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                editor.zoom(by: value / lastMagnification, around: anchor)
                lastMagnification = value
            }
            .onEnded { _ in lastMagnification = 1 }
    }

    // MARK: Overlays

    /// True window full screen, bottom-right. Zooming itself is gesture-only
    /// now (pinch), so this is the lone floating control.
    private var fullscreenControl: some View {
        FloatingGlassButton(symbol: "arrow.up.left.and.arrow.down.right",
                            help: "Toggle Full Screen") {
            (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
        }
    }

    /// A run-level error takes priority; otherwise the first validation issue.
    @ViewBuilder private var statusBadge: some View {
        if let error = run.startupError {
            badge(error, icon: "xmark.octagon.fill", tint: Theme.stateColor(.failed))
        } else {
            let issues = editor.validationIssues
            if let first = issues.first {
                badge(issues.count == 1 ? first.description : "\(issues.count) issues — \(first.description)",
                      icon: "exclamationmark.triangle.fill", tint: Theme.stateColor(.failed))
            }
        }
    }

    private func badge(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).lineLimit(1).foregroundStyle(Theme.textSecondary)
        }
        .font(.oslerBody(11))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Theme.panelRaised))
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    /// Frames the whole graph. Returns false when the viewport isn't usable
    /// yet, so the caller can leave `needsInitialFit` set and try again.
    @discardableResult
    private func fitToContent(viewSize: CGSize) -> Bool {
        // A viewport that hasn't been laid out — or is mid-fullscreen
        // transition — used to produce a negative scale and an offset that
        // parked the graph far off-screen, which read as "the cards vanished".
        guard viewSize.width > 1, viewSize.height > 1 else { return false }

        let nodes = editor.graph.nodes
        guard !nodes.isEmpty else {
            editor.scale = 1; editor.offset = .zero; return true
        }
        let minX = nodes.map(\.position.x).min()!
        let minY = nodes.map(\.position.y).min()!
        let maxX = nodes.map { $0.position.x + NodeGeometry.width }.max()!
        let maxY = nodes.map { $0.position.y + NodeGeometry.height }.max()!
        let contentW = max(maxX - minX, 1), contentH = max(maxY - minY, 1)
        // Padding shrinks with the viewport so the usable area is never
        // negative in a narrow window.
        let padding = min(80, min(viewSize.width, viewSize.height) / 5)
        let usable = CGSize(width: max(viewSize.width - padding * 2, 1),
                            height: max(viewSize.height - padding * 2, 1))
        let scale = min(min(usable.width / contentW, usable.height / contentH), 1.5)
        editor.scale = max(0.3, scale)
        // Center the content bounding box in the viewport.
        editor.offset = CGSize(
            width: viewSize.width / 2 - (minX + contentW / 2) * editor.scale,
            height: viewSize.height / 2 - (minY + contentH / 2) * editor.scale
        )
        return true
    }
}

/// A double-click on empty canvas, remembered until the quick-add popover
/// resolves it into a node at that spot.
struct QuickAddRequest: Identifiable {
    let id = UUID()
    let point: CGPoint // canvas space
}

/// The double-click menu: one row per node kind, added right where you clicked.
private struct QuickAddMenu: View {
    let choose: (NodeKind) -> Void

    private static let kinds: [(NodeKind, String)] = [
        (.input, "Starting text you type"),
        (.agent, "Calls an LLM with a prompt"),
        (.condition, "Routes to a yes/no branch"),
        (.output, "Shows the final text"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.kinds, id: \.0) { kind, subtitle in
                Button { choose(kind) } label: {
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
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
            }
        }
        .padding(8)
        .frame(width: 224)
    }
}

/// A floating glass pill button. Hover lifts the WHOLE control — a slight
/// grow plus a neutral glow (dark halo on light, white glow on dark) — instead
/// of the cheap inner-box highlight row buttons use.
private struct FloatingGlassButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 38, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.hoverFill)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(false)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .scaleEffect(hovering ? 1.09 : 1)
        .shadow(color: .black.opacity(hovering ? 0.14 : 0.05), radius: hovering ? 11 : 8, y: 3)
        .shadow(color: Theme.textPrimary.opacity(hovering ? 0.20 : 0), radius: hovering ? 9 : 0)
        .help(help)
        .onHover { inside in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) { hovering = inside }
        }
    }
}

/// Capsule-shaped sibling of HoverRowStyle: same grow-and-glow hover feel.
struct HoverPillStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(Theme.hoverFill).opacity(hovering ? 1 : 0))
            .scaleEffect(configuration.isPressed ? 0.97 : hovering ? 1.05 : 1)
            .shadow(color: Theme.textPrimary.opacity(hovering ? 0.16 : 0),
                    radius: hovering ? 8 : 0)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: hovering)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// A soft dot lattice (drawn in screen space so dots stay crisp at any zoom).
/// Zooming out doubles the world spacing map-style, so the texture thins out
/// instead of collapsing into noise. Animatable, so animated pans and zooms
/// glide the grid together with the nodes instead of snapping it.
struct GridBackground: View, Animatable {
    var scale: CGFloat
    var offset: CGSize

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(scale, .init(offset.width, offset.height)) }
        set {
            scale = newValue.first
            offset = CGSize(width: newValue.second.first, height: newValue.second.second)
        }
    }

    var body: some View {
        Canvas { context, size in
            var spacing = 32 * scale
            guard spacing > 0.5 else { return }
            while spacing < 22 { spacing *= 2 }
            let radius: CGFloat = 1.4

            var dots = Path()
            var x = offset.width.truncatingRemainder(dividingBy: spacing)
            if x < 0 { x += spacing }
            while x < size.width + radius {
                var y = offset.height.truncatingRemainder(dividingBy: spacing)
                if y < 0 { y += spacing }
                while y < size.height + radius {
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius,
                                               width: radius * 2, height: radius * 2))
                    y += spacing
                }
                x += spacing
            }
            context.fill(dots, with: .color(Theme.gridDot))
        }
    }
}
