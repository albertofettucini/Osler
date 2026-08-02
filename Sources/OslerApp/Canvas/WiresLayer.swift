import SwiftUI
import OslerEngine

/// Draws every edge as a horizontal bezier between the exact port points, plus
/// the in-progress wire the user is dragging. Purely visual — not hit-testable,
/// so empty canvas space still pans.
struct WiresLayer: View {
    @EnvironmentObject var editor: FlowEditor
    @EnvironmentObject var run: RunController

    var body: some View {
        Canvas { context, _ in
            let nodesByID = Dictionary(editor.graph.nodes.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })

            for edge in editor.graph.edges {
                guard let from = nodesByID[edge.from], let to = nodesByID[edge.to],
                      let start = NodeGeometry.outputPortPoint(from, port: edge.fromPort) else { continue }
                let end = NodeGeometry.inputPortPoint(to)
                // A wire is "live" only when a value actually flowed through it:
                // source finished AND the target ran (a skipped target means this
                // was the branch the flow didn't take).
                let targetState = run.state(for: edge.to)
                let live = run.state(for: edge.from) == .done
                    && (targetState == .running || targetState == .done)
                context.stroke(
                    wirePath(from: start, to: end),
                    with: .color(live ? Theme.wireLive : Theme.wire),
                    style: StrokeStyle(lineWidth: live ? 2.4 : 1.8, lineCap: .round)
                )
            }

            if let pending = editor.pendingWire {
                let path: Path?
                switch pending.anchor {
                case .output(let fromID, let port):
                    path = nodesByID[fromID]
                        .flatMap { NodeGeometry.outputPortPoint($0, port: port) }
                        .map { wirePath(from: $0, to: pending.current) }
                case .input(let toID):
                    path = nodesByID[toID]
                        .map { wirePath(from: pending.current, to: NodeGeometry.inputPortPoint($0)) }
                }
                if let path {
                    context.stroke(
                        path,
                        with: .color(Theme.accent.opacity(0.9)),
                        style: StrokeStyle(lineWidth: 2, dash: [5, 4])
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func wirePath(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let (control1, control2) = NodeGeometry.wireControls(from: start, to: end)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }
}
