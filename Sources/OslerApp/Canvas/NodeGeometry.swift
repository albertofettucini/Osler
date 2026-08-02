import CoreGraphics
import OslerEngine

/// Fixed node-card geometry, in world units. Both `NodeView` (which draws the
/// card and its ports) and `WiresLayer` (which draws connections between ports)
/// derive port positions from here, so a wire always meets a port exactly.
enum NodeGeometry {
    static let width: CGFloat = 214
    static let height: CGFloat = 98
    static let portRadius: CGFloat = 6
    static let portHitRadius: CGFloat = 22

    static func rect(_ node: Node) -> CGRect {
        CGRect(x: node.position.x, y: node.position.y, width: width, height: height)
    }

    static func center(_ node: Node) -> CGPoint {
        CGPoint(x: node.position.x + width / 2, y: node.position.y + height / 2)
    }

    static func hasInputPort(_ node: Node) -> Bool {
        node.kind != .input
    }

    /// Output ports and their world positions, left-to-right / top-to-bottom.
    static func outputPorts(_ node: Node) -> [(port: SourcePort, point: CGPoint)] {
        let r = rect(node)
        switch node.kind {
        case .output:
            return []
        case .condition:
            return [
                (.yes, CGPoint(x: r.maxX, y: r.minY + height * 0.36)),
                (.no, CGPoint(x: r.maxX, y: r.minY + height * 0.68)),
            ]
        case .input, .agent, .unknown:
            return [(.output, CGPoint(x: r.maxX, y: r.midY))]
        }
    }

    static func inputPortPoint(_ node: Node) -> CGPoint {
        let r = rect(node)
        return CGPoint(x: r.minX, y: r.midY)
    }

    static func outputPortPoint(_ node: Node, port: SourcePort) -> CGPoint? {
        outputPorts(node).first { $0.port == port }?.point
    }

    // MARK: Wire curve math (shared by drawing, hit-testing, and the ✕ button)

    static func wireControls(from start: CGPoint, to end: CGPoint) -> (CGPoint, CGPoint) {
        let dx = max(40, abs(end.x - start.x) * 0.5)
        return (CGPoint(x: start.x + dx, y: start.y), CGPoint(x: end.x - dx, y: end.y))
    }

    /// Point on the wire's cubic bezier at parameter t ∈ [0, 1].
    static func wirePoint(_ t: CGFloat, from start: CGPoint, to end: CGPoint) -> CGPoint {
        let (c1, c2) = wireControls(from: start, to: end)
        let u = 1 - t
        let x = u * u * u * start.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x
        let y = u * u * u * start.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
        return CGPoint(x: x, y: y)
    }
}
