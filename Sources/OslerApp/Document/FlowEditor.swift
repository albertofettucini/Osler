import SwiftUI
import OslerEngine
import UniformTypeIdentifiers

extension UTType {
    /// Osler flow files. Plain JSON under the hood. Derived from the extension
    /// so no Info.plist type declaration is needed for the SPM executable.
    static let oslerFlow = UTType(filenameExtension: "oslerflow", conformingTo: .json) ?? .json
}

/// A connection the user is currently dragging — from an output port toward a
/// target, or from an input port back toward a source.
struct PendingWire {
    enum Anchor {
        case output(from: UUID, port: SourcePort)
        case input(to: UUID)
    }

    var anchor: Anchor
    var current: CGPoint // in world coordinate space
}

/// The single source of truth for the open flow and all canvas interaction:
/// the graph itself, selection, the pan/zoom transform, and an in-progress
/// wire drag. Every mutation runs through here so the view layer stays dumb.
@MainActor
final class FlowEditor: ObservableObject {
    @Published var graph: FlowGraph {
        didSet {
            isDirty = true
            graphRevision &+= 1
        }
    }
    /// Multi-select: every selected node. Mutating it also closes the current
    /// undo-coalescing burst, so the next edit gets its own undo step.
    @Published var selectedIDs: Set<UUID> = [] { didSet { lastUndoKey = nil } }
    @Published var fileURL: URL?
    @Published var isDirty = false

    /// Single-selection view of `selectedIDs` — most UI (inspector, taps)
    /// thinks in terms of one node. nil when zero or many are selected.
    var selection: UUID? {
        get { selectedIDs.count == 1 ? selectedIDs.first : nil }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }

    // Canvas transform (world → screen: point * scale + offset).
    @Published var scale: CGFloat = 1
    @Published var offset: CGSize = .zero

    // Transient wire drag.
    @Published var pendingWire: PendingWire?

    /// Bumped whenever the whole graph is replaced, so a live canvas re-frames it.
    @Published var fitToken = 0

    /// True until the canvas has framed the current document once. Lives here —
    /// not in view @State — so toggling Workflows/Builder doesn't re-fit and
    /// wipe the user's pan/zoom.
    var needsInitialFit = true

    init(graph: FlowGraph = FlowEditor.starterGraph()) {
        self.graph = graph
        self.isDirty = false
    }

    // MARK: Derived

    var title: String {
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? graph.name
        return base + (isDirty ? " — Edited" : "")
    }

    /// Cached because several view bodies read it on every SwiftUI pass and
    /// the walk is O(V·E) — recomputing it five times per keystroke on a large
    /// flow is the kind of cost that shows up as a laggy canvas.
    private var cachedIssues: [GraphValidationError] = []
    private var cachedIssuesToken = -1
    private var graphRevision = 0

    var validationIssues: [GraphValidationError] {
        if cachedIssuesToken != graphRevision {
            cachedIssues = GraphValidator.issues(in: graph)
            cachedIssuesToken = graphRevision
        }
        return cachedIssues
    }

    var isRunnable: Bool { validationIssues.isEmpty && !graph.nodes.isEmpty }

    func node(_ id: UUID) -> Node? { graph.nodes.first { $0.id == id } }

    var selectedNode: Node? { selection.flatMap(node) }

    /// Node names upstream of the given node — exactly what its `{{Name}}`
    /// references are allowed to reach.
    func upstreamNames(of id: UUID?) -> [String] {
        guard let id, let ancestors = GraphValidator.ancestorNames(in: graph)[id] else { return [] }
        return graph.nodes
            .filter { ancestors.contains(FlowReference.key($0.name)) }
            .map(\.name)
    }

    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    // MARK: Undo / redo (whole-graph snapshots)

    private var undoStack: [FlowGraph] = []
    private var redoStack: [FlowGraph] = []
    private var lastUndoKey: String?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Pushes the current graph as an undo step. A non-nil `coalescing` key
    /// collapses bursts (typing, slider drags): consecutive records with the
    /// same key keep only the first snapshot, so undo returns to the start of
    /// the burst instead of replaying every keystroke.
    private func recordUndo(coalescing key: String? = nil) {
        if let key, key == lastUndoKey { return }
        lastUndoKey = key
        undoStack.append(graph)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(graph)
        lastUndoKey = nil
        apply(snapshot: previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(graph)
        lastUndoKey = nil
        apply(snapshot: next)
    }

    private func apply(snapshot: FlowGraph) {
        graph = snapshot
        selectedIDs = selectedIDs.filter { id in snapshot.nodes.contains { $0.id == id } }
    }

    // MARK: Node mutations

    func addNode(_ kind: NodeKind, at world: CGPoint) {
        let config: NodeConfig
        switch kind {
        case .input: config = .input(text: "")
        case .agent: config = .agent(AgentConfig())
        case .condition: config = .condition(.containsKeyword(""))
        case .output: config = .output
        case .unknown: return
        }
        let node = Node(position: Point(x: world.x, y: world.y), config: config)
        recordUndo()
        // Animated so the card's birth "pop" (NodeView.appeared) lands with a
        // spring no matter which entry point added it.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
            graph.nodes.append(node)
            selection = node.id
        }
    }

    // MARK: Moving (single anchor drives the whole selection)

    private var moveOrigins: [UUID: Point] = [:]

    /// Starts a card drag: one undo snapshot for the whole gesture, and the
    /// origin of every selected node so the group moves as one.
    func beginMove(anchoredAt id: UUID) {
        recordUndo()
        if !selectedIDs.contains(id) { selectedIDs = [id] }
        moveOrigins = [:]
        for nid in selectedIDs {
            if let n = node(nid) { moveOrigins[nid] = n.position }
        }
    }

    func moveSelection(anchoredAt id: UUID, to world: CGPoint) {
        guard let anchor = moveOrigins[id] else { return }
        let dx = world.x - anchor.x
        let dy = world.y - anchor.y
        for (nid, origin) in moveOrigins {
            guard let index = graph.nodes.firstIndex(where: { $0.id == nid }) else { continue }
            graph.nodes[index].position = Point(x: origin.x + dx, y: origin.y + dy)
        }
    }

    func endMove() { moveOrigins = [:] }

    func updateNode(_ id: UUID, _ transform: (inout Node) -> Void) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        recordUndo(coalescing: "edit-\(id)")
        transform(&graph.nodes[index])
    }

    func rename(_ id: UUID, to name: String) {
        updateNode(id) { $0.name = name.isEmpty ? Node.defaultName(for: $0.kind) : name }
    }

    func deleteSelection() {
        guard !selectedIDs.isEmpty else { return }
        recordUndo()
        for id in selectedIDs { removeNodeAndWires(id) }
        selectedIDs = []
    }

    func delete(_ id: UUID) {
        recordUndo()
        removeNodeAndWires(id)
        selectedIDs.remove(id)
    }

    private func removeNodeAndWires(_ id: UUID) {
        graph.nodes.removeAll { $0.id == id }
        graph.edges.removeAll { $0.from == id || $0.to == id }
    }

    /// Copies a node (config and name included, wires not), slightly offset.
    func duplicate(_ id: UUID) {
        guard let source = node(id) else { return }
        recordUndo()
        var copy = Node(position: Point(x: source.position.x + 28, y: source.position.y + 28),
                        config: source.config)
        copy.name = source.name
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
            graph.nodes.append(copy)
            selection = copy.id
        }
    }

    /// Severs every wire touching the node, keeping the node itself.
    func disconnectAll(node id: UUID) {
        guard graph.edges.contains(where: { $0.from == id || $0.to == id }) else { return }
        recordUndo()
        graph.edges.removeAll { $0.from == id || $0.to == id }
    }

    // MARK: Edge mutations

    /// Toggle semantics: a new connection is added; dragging an existing
    /// connection again removes it. Fan-out (one port → many nodes) and fan-in
    /// (many nodes → one input, joined by the engine) are both allowed — the
    /// validator rejects anything structurally invalid.
    func connect(from: UUID, port: SourcePort, to: UUID) {
        guard from != to, node(to)?.kind != .input, node(from)?.kind != .output else { return }
        recordUndo()
        if let existing = graph.edges.first(where: { $0.from == from && $0.fromPort == port && $0.to == to }) {
            graph.edges.removeAll { $0.id == existing.id }
        } else {
            graph.edges.append(Edge(from: from, fromPort: port, to: to))
        }
    }

    func disconnect(_ edgeID: UUID) {
        guard graph.edges.contains(where: { $0.id == edgeID }) else { return }
        recordUndo()
        graph.edges.removeAll { $0.id == edgeID }
    }

    // Port-dot clicks sever every wire attached to that port.

    func hasEdges(from nodeID: UUID, port: SourcePort) -> Bool {
        graph.edges.contains { $0.from == nodeID && $0.fromPort == port }
    }

    func hasEdges(into nodeID: UUID) -> Bool {
        graph.edges.contains { $0.to == nodeID }
    }

    func disconnectAll(from nodeID: UUID, port: SourcePort) {
        guard hasEdges(from: nodeID, port: port) else { return }
        recordUndo()
        graph.edges.removeAll { $0.from == nodeID && $0.fromPort == port }
    }

    func disconnectAll(into nodeID: UUID) {
        guard hasEdges(into: nodeID) else { return }
        recordUndo()
        graph.edges.removeAll { $0.to == nodeID }
    }

    // MARK: File

    /// Replaces the whole document and asks the canvas to re-frame.
    func loadGraph(_ newGraph: FlowGraph, url: URL?) {
        graph = newGraph
        fileURL = url
        selectedIDs = []
        undoStack = []
        redoStack = []
        lastUndoKey = nil
        isDirty = false
        needsInitialFit = true
        fitToken += 1
    }

    func newFlow() {
        loadGraph(FlowGraph(name: "Untitled Flow"), url: nil)
    }

    /// Returns true when the file actually replaced the open document — callers
    /// must not reset run state or switch screens otherwise.
    @discardableResult
    func load(_ url: URL) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            // The flow decoder is deliberately tolerant of missing fields (old
            // files must keep opening), which means a foreign JSON file would
            // "decode" as an empty flow — and a later Save would overwrite the
            // original. Require the one key every flow file has.
            // Every Osler node carries an id and a type; requiring that shape
            // keeps someone else's JSON (which may well have a "nodes" key)
            // from opening as a near-empty flow that Save would then destroy.
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let nodes = object?["nodes"] as? [[String: Any]]
            let looksLikeAFlow = nodes.map { list in
                list.isEmpty || list.contains { $0["id"] != nil && $0["type"] != nil }
            } ?? false
            guard looksLikeAFlow else {
                Alerts.error(
                    "Not an Osler flow",
                    "\"\(url.lastPathComponent)\" isn't an Osler flow file, so it wasn't opened."
                )
                return false
            }
            loadGraph(try FlowGraph(jsonData: data), url: url)
            RecentFlows.add(url)
            return true
        } catch {
            Alerts.error(
                "Couldn't open \"\(url.lastPathComponent)\"",
                error.localizedDescription
            )
            return false
        }
    }

    func save(to url: URL) {
        do {
            var toSave = graph
            toSave.name = url.deletingPathExtension().lastPathComponent
            try toSave.write(to: url)
            graph = toSave
            fileURL = url
            isDirty = false
            RecentFlows.add(url)
        } catch {
            Alerts.error(
                "Couldn't save \"\(url.lastPathComponent)\"",
                "Your changes are still in the editor. \(error.localizedDescription)"
            )
        }
    }

    // MARK: Transform helpers

    func worldToScreen(_ point: Point) -> CGPoint {
        CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }

    func screenToWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / scale, y: (point.y - offset.height) / scale)
    }

    func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let newScale = min(max(scale * factor, 0.3), 2.5)
        // Keep the point under `anchor` fixed while zooming.
        let world = screenToWorld(anchor)
        scale = newScale
        offset = CGSize(width: anchor.x - world.x * scale, height: anchor.y - world.y * scale)
    }

    // MARK: Starter content

    // nonisolated: pure factory, safe to call from the init default argument.
    nonisolated static func starterGraph() -> FlowGraph {
        StarterTemplates.all.first!.make()
    }
}
