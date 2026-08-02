import SwiftUI
import OslerEngine

/// One node card on the canvas: header, a live body preview, and its ports.
/// Owns two gestures — drag the body to move the node, drag an output port to
/// wire it to another node's input.
struct NodeView: View {
    let node: Node
    @EnvironmentObject var editor: FlowEditor
    @EnvironmentObject var run: RunController
    @EnvironmentObject var settings: SettingsStore

    @Environment(\.colorScheme) private var colorScheme

    @State private var dragStartOrigin: Point?
    @State private var hovering = false
    @FocusState private var editingText: Bool

    private var isSelected: Bool { editor.selectedIDs.contains(node.id) }

    /// "Paper" tints (white, pearl) paint the card in that colour at FULL
    /// strength and force the card's content into its light-appearance ink —
    /// a 20% wash of near-white would only read as gray on the dark surface.
    private var paperFill: Color? {
        guard let tint = BackdropTint.by(id: settings.nodeTintID),
              tint.family == .paper, let hex = tint.colors.first else { return nil }
        return Color(hex: hex)
    }
    private var isDragging: Bool { dragStartOrigin != nil }
    private var tint: Color { Theme.nodeTint(node.kind) }
    private var state: NodeRunState { run.state(for: node.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.surfaceVariant)
            cardBody
        }
        .frame(width: NodeGeometry.width, height: NodeGeometry.height, alignment: .top)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(paperFill ?? Theme.nodeSurface)
                // Optional user-picked wash over the card — kept subtle so
                // the (alpha-ink) text stays readable on every tint. Paper
                // tints are special-cased above at full strength.
                if paperFill == nil, let cardTint = BackdropTint.by(id: settings.nodeTintID) {
                    cardTint.gradient.opacity(0.20)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        )
        .overlay(
            // Selected = a brighter neutral, never color (§2).
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Theme.textPrimary.opacity(0.65) : Theme.nodeBorder,
                              lineWidth: isSelected ? 1.6 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.textPrimary.opacity(isSelected ? 0.14 : 0), lineWidth: 3)
                .padding(-3)
        )
        // Lift: deeper drop shadow while the card is held.
        .shadow(color: .black.opacity(isDragging ? 0.20 : isSelected ? 0.10 : 0.05),
                radius: isDragging ? 22 : isSelected ? 16 : 10,
                y: isDragging ? 11 : 6)
        // The app-wide hover glow — neutral (white on dark, ink halo on light).
        .shadow(color: Theme.textPrimary.opacity(hovering || isDragging ? 0.20 : 0),
                radius: hovering || isDragging ? 11 : 0, y: 2)
        // The card's hit shape MUST be set before the ports overlay: applied
        // after it, the rounded rect would gate hit-testing for the whole
        // composite — and the port dots sit ON the card edge, so their outer
        // half and grab halo would land in a dead zone outside the shape.
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .overlay(ports)
        // Visibility must never depend on an animation flag: a missed onAppear
        // would leave the card permanently invisible. The birth "pop" is a
        // transition instead (see the ForEach in CanvasView) — if the
        // insertion isn't animated the card simply appears, fully drawn.
        .opacity(dimmed ? 0.45 : 1)
        .scaleEffect(isDragging ? 1.03 : hovering ? 1.02 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: hovering)
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isDragging)
        // BEFORE .position: onHover installs a tracking area over the view's
        // FRAME, and the position wrapper spans the whole world container —
        // attached there, the topmost node would swallow hover for the entire
        // canvas. Here the tracking area is just this card.
        .onHover { hovering = $0 }
        .position(NodeGeometry.center(node))
        // NOTE: instant mouse-down selection lives in CanvasView's NSEvent
        // monitor (ScrollPanCatcher.onMouseDown) — a competing gesture here
        // (zero-distance drag OR zero-duration long-press) starves moveGesture
        // and makes cards undraggable.
        .gesture(moveGesture)
        // Double first so it wins; the single tap (select) only fires once a
        // double-click is ruled out.
        .onTapGesture(count: 2) {
            if settings.doubleClickRemoves {
                editor.delete(node.id)
            } else {
                editor.selection = node.id
            }
        }
        .onTapGesture {
            // A plain click collapses to a single selection; shift-clicks are
            // handled at mouse-down (canvas monitor) and must not collapse.
            if !NSEvent.modifierFlags.contains(.shift) {
                editor.selection = node.id
            }
        }
        .contextMenu {
            Button {
                editor.duplicate(node.id)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                editor.disconnectAll(node: node.id)
            } label: {
                Label("Disconnect All Wires", systemImage: "scissors")
            }
            Divider()
            Button(role: .destructive) {
                editor.delete(node.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        // A paper card resolves every dynamic colour inside it (text, ports,
        // chips) in its light variant, so ink stays ink on white — even when
        // the app is in dark mode.
        .environment(\.colorScheme, paperFill != nil ? .light : colorScheme)
    }

    /// Un-started branches after a run dim so the taken path stands out.
    private var dimmed: Bool {
        run.hasRun && state == .skipped
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: Theme.nodeGlyph(node.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint))
            Text(node.name)
                .font(.oslerBody(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            stateIndicator
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    /// The design's soft status chip ("Connected"-style); a spinner while running.
    @ViewBuilder private var stateIndicator: some View {
        switch state {
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
        case .done, .failed, .skipped:
            Text(state == .done ? "Done" : state == .failed ? "Failed" : "Skipped")
                .font(.oslerLabel(9))
                .foregroundStyle(Theme.stateColor(state))
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Capsule().fill(Theme.stateChipBackground(state)))
                .overlay(Capsule().strokeBorder(Theme.stateColor(state).opacity(0.25)))
        case .idle:
            EmptyView()
        }
    }

    // MARK: Body

    private var cardBody: some View {
        Group {
            if let output = run.outputs[node.id], !output.isEmpty, state != .idle {
                Text(output + (run.streaming.contains(node.id) ? "▍" : ""))
                    .font(.oslerBody(11))
                    .foregroundStyle(state == .failed ? Theme.stateColor(.failed) : Theme.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if node.kind == .input, editor.selection == node.id {
                // The card promises "click to add starting text" — deliver it:
                // a selected Input node edits its text right on the card.
                TextField("Type the starting text…", text: inputTextBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.oslerBody(11))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                    .focused($editingText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onAppear { editingText = true }
            } else {
                Text(NodeSummary.subtitle(node))
                    .font(.oslerBody(11))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Live binding into the Input node's text — every keystroke lands in the
    /// graph (and the inspector mirrors it).
    private var inputTextBinding: Binding<String> {
        Binding(
            get: {
                if case .input(let text) = node.config { return text }
                return ""
            },
            set: { newValue in
                editor.updateNode(node.id) { $0.config = .input(text: newValue) }
            }
        )
    }

    // MARK: Ports

    private var ports: some View {
        ZStack {
            if NodeGeometry.hasInputPort(node) {
                portDot(filled: false)
                    .position(x: 0, y: NodeGeometry.height / 2)
                    .gesture(inputDragGesture)
                    // A plain click on the dot severs its wires (drag still wires).
                    .onTapGesture {
                        if editor.hasEdges(into: node.id) {
                            editor.disconnectAll(into: node.id)
                        } else {
                            editor.selection = node.id
                        }
                    }
            }
            ForEach(NodeGeometry.outputPorts(node), id: \.port) { entry in
                portDot(filled: true, label: portLabel(entry.port))
                    .position(x: NodeGeometry.width,
                              y: entry.point.y - node.position.y)
                    .gesture(portDragGesture(port: entry.port))
                    .onTapGesture {
                        if editor.hasEdges(from: node.id, port: entry.port) {
                            editor.disconnectAll(from: node.id, port: entry.port)
                        } else {
                            editor.selection = node.id
                        }
                    }
            }
        }
    }

    private func portLabel(_ port: SourcePort) -> String? {
        switch port {
        case .yes: return "Y"
        case .no: return "N"
        case .output: return nil
        }
    }

    private func portDot(filled: Bool, label: String? = nil) -> some View {
        ZStack {
            // Design language: light ring with the accent core (surface-toned
            // so it doesn't glare on the dark canvas).
            Circle()
                .fill(Theme.nodeSurfaceRaised)
                .overlay(Circle().strokeBorder(filled ? tint : Theme.outlineVariant, lineWidth: 1.4))
                .frame(width: NodeGeometry.portRadius * 2, height: NodeGeometry.portRadius * 2)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            if let label {
                Text(label)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tint)
            } else if filled {
                Circle().fill(tint).frame(width: 5.5, height: 5.5)
            }
        }
        // The inset is in world units but hit-testing happens after the zoom
        // transform — divide by scale so the grab target keeps a constant
        // screen size instead of shrinking to a pixel hunt when zoomed out.
        .contentShape(Circle().inset(by: -12 / editor.scale))
    }

    // MARK: Gestures

    // Both gestures measure in the untransformed "canvas" (screen) space and
    // convert to world coordinates explicitly — a screen translation divided by
    // the zoom scale is a world translation, so dragging tracks the cursor 1:1
    // at any zoom level.

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named("canvas"))
            .onChanged { value in
                if dragStartOrigin == nil {
                    dragStartOrigin = node.position
                    // Keeps the selection when dragging a member of it, so the
                    // whole group travels together.
                    editor.beginMove(anchoredAt: node.id)
                }
                guard let origin = dragStartOrigin else { return }
                editor.moveSelection(anchoredAt: node.id, to: CGPoint(
                    x: origin.x + value.translation.width / editor.scale,
                    y: origin.y + value.translation.height / editor.scale
                ))
            }
            .onEnded { _ in
                dragStartOrigin = nil
                editor.endMove()
            }
    }

    private func portDragGesture(port: SourcePort) -> some Gesture {
        DragGesture(coordinateSpace: .named("canvas"))
            .onChanged { value in
                editor.pendingWire = PendingWire(
                    anchor: .output(from: node.id, port: port),
                    current: editor.screenToWorld(value.location)
                )
            }
            .onEnded { value in
                defer { editor.pendingWire = nil }
                if let target = dropTarget(at: editor.screenToWorld(value.location)) {
                    editor.connect(from: node.id, port: port, to: target.id)
                }
            }
    }

    /// Dragging out of an input port connects the other way around: drop on a
    /// source card (or its output port) to wire source → this node.
    private var inputDragGesture: some Gesture {
        DragGesture(coordinateSpace: .named("canvas"))
            .onChanged { value in
                editor.pendingWire = PendingWire(
                    anchor: .input(to: node.id),
                    current: editor.screenToWorld(value.location)
                )
            }
            .onEnded { value in
                defer { editor.pendingWire = nil }
                let drop = editor.screenToWorld(value.location)
                if let (source, port) = sourceTarget(at: drop) {
                    editor.connect(from: source.id, port: port, to: node.id)
                }
            }
    }

    /// Resolves where a wire drop lands. A drop on a card goes to that card —
    /// the topmost one when cards overlap (nodes render in array order, so the
    /// later element is drawn on top). Otherwise the nearest input port within
    /// a constant screen-feel tolerance wins.
    private func dropTarget(at drop: CGPoint) -> Node? {
        let candidates = editor.graph.nodes.filter {
            $0.id != node.id && NodeGeometry.hasInputPort($0)
        }
        if let onCard = candidates.last(where: {
            NodeGeometry.rect($0).insetBy(dx: -8, dy: -8).contains(drop)
        }) {
            return onCard
        }
        let tolerance = NodeGeometry.portHitRadius / editor.scale
        return candidates
            .map { candidate -> (node: Node, distance: CGFloat) in
                let port = NodeGeometry.inputPortPoint(candidate)
                return (candidate, hypot(port.x - drop.x, port.y - drop.y))
            }
            .filter { $0.distance < tolerance }
            .min { $0.distance < $1.distance }?
            .node
    }

    /// The reverse resolution for input-port drags: which node (and which of
    /// its output ports — conditions have two) should feed this one.
    private func sourceTarget(at drop: CGPoint) -> (Node, SourcePort)? {
        let candidates = editor.graph.nodes.filter {
            $0.id != node.id && !NodeGeometry.outputPorts($0).isEmpty
        }
        func nearestPort(of candidate: Node) -> (port: SourcePort, distance: CGFloat)? {
            NodeGeometry.outputPorts(candidate)
                .map { ($0.port, hypot($0.point.x - drop.x, $0.point.y - drop.y)) }
                .min { $0.1 < $1.1 }
        }
        if let onCard = candidates.last(where: {
            NodeGeometry.rect($0).insetBy(dx: -8, dy: -8).contains(drop)
        }), let hit = nearestPort(of: onCard) {
            return (onCard, hit.port)
        }
        let tolerance = NodeGeometry.portHitRadius / editor.scale
        return candidates
            .compactMap { candidate -> (Node, SourcePort, CGFloat)? in
                guard let hit = nearestPort(of: candidate), hit.distance < tolerance else { return nil }
                return (candidate, hit.port, hit.distance)
            }
            .min { $0.2 < $1.2 }
            .map { ($0.0, $0.1) }
    }
}

/// One-line description of a node's configuration, shown when it isn't running.
enum NodeSummary {
    static func subtitle(_ node: Node) -> String {
        switch node.config {
        case .input(let text):
            return text.isEmpty ? "Empty — click to add starting text" : text
        case .agent(let config):
            let system = config.systemPrompt.isEmpty ? "No system prompt" : config.systemPrompt
            return "\(config.model)\n\(system)"
        case .condition(let rule):
            switch rule {
            case .containsKeyword(let keyword):
                return keyword.isEmpty ? "Contains… (set a keyword)" : "Contains \"\(keyword)\""
            case .llmYesNo(let question, _, _):
                return question.isEmpty ? "LLM yes/no (set a question)" : "Ask: \(question)"
            }
        case .output:
            return "Shows the final text"
        case .unknown(let rawType, _):
            return "Unsupported node (\(rawType)) — from a newer version"
        }
    }
}
