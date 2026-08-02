import SwiftUI
import OslerEngine

/// A flow at a glance: the real graph, shrunk to fit — node dots in their type
/// colours, edges as the same curves the canvas draws. Because it renders the
/// actual positions, a template's shape (a branch, three parallel agents, a
/// fan-in) is readable before it's ever opened.
struct FlowThumbnail: View {
    let graph: FlowGraph
    var dotRadius: CGFloat = 3.5

    var body: some View {
        Canvas { context, size in
            guard !graph.nodes.isEmpty else { return }
            let centers = Dictionary(
                graph.nodes.map { ($0.id, NodeGeometry.center($0)) },
                uniquingKeysWith: { first, _ in first }
            )
            let project = projector(for: Array(centers.values), in: size)

            for edge in graph.edges {
                guard let from = centers[edge.from], let to = centers[edge.to] else { continue }
                let start = project(from), end = project(to)
                var path = Path()
                path.move(to: start)
                // Gentle horizontal S-curve, echoing the canvas wires.
                let dx = max(6, abs(end.x - start.x) * 0.45)
                path.addCurve(to: end,
                              control1: CGPoint(x: start.x + dx, y: start.y),
                              control2: CGPoint(x: end.x - dx, y: end.y))
                context.stroke(path, with: .color(Theme.wire), lineWidth: 1.4)
            }

            for node in graph.nodes {
                guard let center = centers[node.id] else { continue }
                let point = project(center)
                let rect = CGRect(x: point.x - dotRadius, y: point.y - dotRadius,
                                  width: dotRadius * 2, height: dotRadius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Theme.nodeTint(node.kind)))
            }
        }
        .allowsHitTesting(false)
    }

    /// Fits the graph's bounding box into `size`, centred, preserving aspect.
    /// Degenerate boxes (a single row of nodes) collapse to one axis, so both
    /// spans are floored before dividing.
    private func projector(for points: [CGPoint], in size: CGSize) -> (CGPoint) -> CGPoint {
        let inset = dotRadius + 3
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
        let spanX = max(maxX - minX, 1), spanY = max(maxY - minY, 1)
        let usable = CGSize(width: max(size.width - inset * 2, 1),
                            height: max(size.height - inset * 2, 1))
        let scale = min(usable.width / spanX, usable.height / spanY)
        let drawnW = spanX * scale, drawnH = spanY * scale
        let originX = inset + (usable.width - drawnW) / 2
        let originY = inset + (usable.height - drawnH) / 2
        return { point in
            CGPoint(x: (point.x - minX) * scale + originX,
                    y: (point.y - minY) * scale + originY)
        }
    }
}
