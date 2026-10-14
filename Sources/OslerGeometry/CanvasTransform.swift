import CoreGraphics

/// The canvas pan/zoom transform: how world coordinates (where nodes live)
/// map to screen coordinates (where the pointer and the viewport live).
///
/// World → screen is `point * scale + offset`. This is exactly what the node
/// layer's `.scaleEffect(scale, anchor: .topLeading).offset(offset)` draws, and
/// what the screen-space wire canvas applies through `affine` — both layers
/// derive from this one value, so a wire always meets its port.
///
/// A plain value type with no UI dependency, so the math is tested directly.
public struct CanvasTransform: Equatable, Sendable {
    /// Screen points per world unit.
    public var scale: CGFloat
    /// Screen-space translation, applied after scaling.
    public var offset: CGSize

    /// A fresh canvas, and what an empty document resets to.
    public static let identity = CanvasTransform()

    /// Interactive (pinch) zoom limits.
    public static let zoomLimits: ClosedRange<CGFloat> = 0.3...2.5

    public init(scale: CGFloat = 1, offset: CGSize = .zero) {
        self.scale = scale
        self.offset = offset
    }

    /// Where a world point lands on screen.
    public func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }

    /// Which world point sits under a screen point.
    public func world(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / scale, y: (point.y - offset.height) / scale)
    }

    /// The same mapping as an affine transform, for drawing world-space paths
    /// into a screen-space `Canvas` (`context.concatenate(affine)`). Strokes
    /// drawn under it scale with the zoom, just like content under
    /// `.scaleEffect` does.
    public var affine: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.width, ty: offset.height)
    }

    /// The transform as SwiftUI puts `.offset` on screen: the translation is
    /// snapped to the device-pixel grid (round half up), the scale is not.
    /// The node layer gets this snapping for free; a screen-space `Canvas`
    /// drawing with the exact offset would sit up to half a pixel off the
    /// ports, so it draws with this instead.
    public func pixelAligned(displayScale: CGFloat) -> CanvasTransform {
        guard displayScale > 0, displayScale.isFinite else { return self }
        func snap(_ value: CGFloat) -> CGFloat {
            (value * displayScale + 0.5).rounded(.down) / displayScale
        }
        return CanvasTransform(scale: scale,
                               offset: CGSize(width: snap(offset.width), height: snap(offset.height)))
    }

    /// What a screen-space `Canvas` concatenates to draw world-space paths
    /// where the node layer shows them: the pixel-aligned affine. The wire
    /// layer and its parity test both draw through this one function, so the
    /// test covers the shipped transform, not a copy of it.
    public func drawingTransform(displayScale: CGFloat) -> CGAffineTransform {
        pixelAligned(displayScale: displayScale).affine
    }

    /// Zooms about a fixed screen point: the world point under `anchor` stays
    /// under it. The new scale is clamped to `zoomLimits`.
    public func zoomed(by factor: CGFloat, around anchor: CGPoint) -> CanvasTransform {
        let newScale = min(max(scale * factor, Self.zoomLimits.lowerBound), Self.zoomLimits.upperBound)
        let fixed = world(anchor)
        return CanvasTransform(
            scale: newScale,
            offset: CGSize(width: anchor.x - fixed.x * newScale, height: anchor.y - fixed.y * newScale)
        )
    }

    /// Frames a world-space bounding box in a viewport, centred, with padding
    /// that shrinks with the viewport (so the usable area is never negative in
    /// a narrow window). Scale is kept within 0.3...1.5 so a two-node flow
    /// isn't blown up to fill a monitor.
    ///
    /// Returns nil when the viewport hasn't been laid out yet (or is
    /// mid-fullscreen-transition) — fitting then used to produce a negative
    /// scale that parked the graph off-screen. The caller retries later.
    public static func fitting(_ content: CGRect, in viewSize: CGSize) -> CanvasTransform? {
        guard viewSize.width > 1, viewSize.height > 1 else { return nil }
        let contentW = max(content.width, 1), contentH = max(content.height, 1)
        let padding = min(80, min(viewSize.width, viewSize.height) / 5)
        let usable = CGSize(width: max(viewSize.width - padding * 2, 1),
                            height: max(viewSize.height - padding * 2, 1))
        let raw = min(min(usable.width / contentW, usable.height / contentH), 1.5)
        let scale = max(0.3, raw)
        return CanvasTransform(
            scale: scale,
            offset: CGSize(width: viewSize.width / 2 - (content.minX + contentW / 2) * scale,
                           height: viewSize.height / 2 - (content.minY + contentH / 2) * scale)
        )
    }
}
