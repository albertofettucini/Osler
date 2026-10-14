import CoreGraphics
import Observation

/// The live pan/zoom state of the builder canvas.
///
/// Deliberately separate from the document (FlowEditor): a pan tick changes
/// `offset` dozens of times a second, and if that went through the editor's
/// `objectWillChange` every view that observes the editor — every node card,
/// the inspector, the library, the menu commands — re-rendered on each tick.
///
/// `@Observable` tracks per property, so a view that only reads `scale` (a
/// port's grab halo) is invalidated by a zoom but NOT by a pan, and a view
/// that reads neither is never touched. Only the few layers that actually draw
/// the transform read `offset` in their body.
@MainActor
@Observable
public final class CanvasViewport {
    /// Screen points per world unit.
    public private(set) var scale: CGFloat
    /// Screen-space translation, applied after scaling.
    public private(set) var offset: CGSize

    public init(_ transform: CanvasTransform = .identity) {
        scale = transform.scale
        offset = transform.offset
    }

    /// Both components at once. Reading this tracks both; prefer `scale` or
    /// `offset` alone in a view body when only one is needed.
    public var transform: CanvasTransform {
        get { CanvasTransform(scale: scale, offset: offset) }
        set { apply(newValue) }
    }

    /// Writes only the components that actually changed, so e.g. a pinch held
    /// at the zoom limit doesn't keep invalidating every scale reader.
    public func apply(_ transform: CanvasTransform) {
        if transform.scale != scale { scale = transform.scale }
        if transform.offset != offset { offset = transform.offset }
    }

    public func setScale(_ newScale: CGFloat) {
        apply(CanvasTransform(scale: newScale, offset: offset))
    }

    public func setOffset(_ newOffset: CGSize) {
        apply(CanvasTransform(scale: scale, offset: newOffset))
    }

    /// Pans by a screen-space delta (trackpad scroll).
    public func pan(by delta: CGSize) {
        setOffset(CGSize(width: offset.width + delta.width, height: offset.height + delta.height))
    }

    public func zoom(by factor: CGFloat, around anchor: CGPoint) {
        apply(transform.zoomed(by: factor, around: anchor))
    }

    public func screenToWorld(_ point: CGPoint) -> CGPoint { transform.world(point) }
    public func worldToScreen(_ point: CGPoint) -> CGPoint { transform.screen(point) }
}
