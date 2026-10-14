import SwiftUI
import OslerEngine
import OslerGeometry

/// Draws every edge as a horizontal bezier between the exact port points, plus
/// the in-progress wire the user is dragging. Purely visual — not hit-testable,
/// so empty canvas space still pans.
///
/// Drawn in SCREEN space: the canvas is only as big as the viewport, and the
/// world → screen transform is applied inside it. It used to live inside the
/// 6000×4000 world container under `.scaleEffect`, which made it a
/// ~12000×8000 px layer re-rasterised on every pan tick. The transform is the
/// same `CanvasTransform` the node layer's scaleEffect+offset draws (pixel
/// snapping included), and the paths are still built in world units, so wires
/// stay glued to the ports and strokes keep scaling with the zoom exactly as
/// before.
///
/// Animatable like `GridBackground`, so a pan/zoom that happens inside an
/// animation glides the wires together with the cards.
struct WiresLayer: View, Animatable {
    var scale: CGFloat
    var offset: CGSize

    @EnvironmentObject var editor: FlowEditor
    @EnvironmentObject var run: RunController
    @Environment(\.displayScale) private var displayScale

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(scale, .init(offset.width, offset.height)) }
        set {
            scale = newValue.first
            offset = CGSize(width: newValue.second.first, height: newValue.second.second)
        }
    }

    var body: some View {
        // Pixel-aligned exactly as the cards' `.offset` is rendered, so wire
        // ends land on the port dots to the device pixel.
        let transform = CanvasTransform(scale: scale, offset: offset)
            .drawingTransform(displayScale: displayScale)
        Canvas { context, _ in
            context.concatenate(transform)

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
