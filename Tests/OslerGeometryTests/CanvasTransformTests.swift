import CoreGraphics
import XCTest
@testable import OslerGeometry

/// The formulas FlowEditor / CanvasView used inline before the transform was
/// extracted, kept verbatim so the new code is checked against the old.
private enum Legacy {
    static func worldToScreen(_ p: CGPoint, scale: CGFloat, offset: CGSize) -> CGPoint {
        CGPoint(x: p.x * scale + offset.width, y: p.y * scale + offset.height)
    }

    static func screenToWorld(_ p: CGPoint, scale: CGFloat, offset: CGSize) -> CGPoint {
        CGPoint(x: (p.x - offset.width) / scale, y: (p.y - offset.height) / scale)
    }

    static func zoom(scale: CGFloat, offset: CGSize, by factor: CGFloat,
                     around anchor: CGPoint) -> (CGFloat, CGSize) {
        let newScale = min(max(scale * factor, 0.3), 2.5)
        let world = screenToWorld(anchor, scale: scale, offset: offset)
        return (newScale, CGSize(width: anchor.x - world.x * newScale,
                                 height: anchor.y - world.y * newScale))
    }

    /// CanvasView.fitToContent before the extraction (non-empty graph).
    static func fit(minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat,
                    viewSize: CGSize) -> (CGFloat, CGSize)? {
        guard viewSize.width > 1, viewSize.height > 1 else { return nil }
        let contentW = max(maxX - minX, 1), contentH = max(maxY - minY, 1)
        let padding = min(80, min(viewSize.width, viewSize.height) / 5)
        let usable = CGSize(width: max(viewSize.width - padding * 2, 1),
                            height: max(viewSize.height - padding * 2, 1))
        let scale = max(0.3, min(min(usable.width / contentW, usable.height / contentH), 1.5))
        return (scale, CGSize(width: viewSize.width / 2 - (minX + contentW / 2) * scale,
                              height: viewSize.height / 2 - (minY + contentH / 2) * scale))
    }

    /// What `.scaleEffect(scale, anchor: .topLeading).offset(offset)` does to
    /// a point of the world container (whose origin is the canvas origin):
    /// scale about the top-left corner, then translate.
    static func scaleEffectThenOffset(scale: CGFloat, offset: CGSize) -> CGAffineTransform {
        CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: offset.width, y: offset.height))
    }
}

final class CanvasTransformTests: XCTestCase {
    private var rng = SystemRandomNumberGenerator()

    private func randomTransform() -> CanvasTransform {
        CanvasTransform(scale: .random(in: 0.3...2.5, using: &rng),
                        offset: CGSize(width: .random(in: -4000...4000, using: &rng),
                                       height: .random(in: -4000...4000, using: &rng)))
    }

    private func randomPoint(_ range: ClosedRange<CGFloat> = -6000...6000) -> CGPoint {
        CGPoint(x: .random(in: range, using: &rng), y: .random(in: range, using: &rng))
    }

    private func assertClose(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testPointConversionMatchesLegacyFormulas() {
        for _ in 0..<500 {
            let t = randomTransform()
            let p = randomPoint()
            XCTAssertEqual(t.screen(p), Legacy.worldToScreen(p, scale: t.scale, offset: t.offset))
            XCTAssertEqual(t.world(p), Legacy.screenToWorld(p, scale: t.scale, offset: t.offset))
        }
    }

    func testRoundTrips() {
        for _ in 0..<500 {
            let t = randomTransform()
            let p = randomPoint()
            assertClose(t.world(t.screen(p)), p, accuracy: 1e-6)
            assertClose(t.screen(t.world(p)), p, accuracy: 1e-6)
        }
    }

    /// The screen-space wire canvas draws with `affine`; the node cards are
    /// drawn with scaleEffect(.topLeading) + offset. They must agree exactly
    /// for every port point, or wires would detach from their ports.
    func testAffineMatchesNodeLayerComposition() {
        for _ in 0..<500 {
            let t = randomTransform()
            let legacy = Legacy.scaleEffectThenOffset(scale: t.scale, offset: t.offset)
            let p = randomPoint()
            assertClose(p.applying(t.affine), t.screen(p), accuracy: 1e-6)
            assertClose(p.applying(t.affine), p.applying(legacy), accuracy: 1e-6)
        }
    }

    /// A whole wire path (bezier included) transformed by `affine` lands where
    /// the endpoints and control points map individually — i.e. drawing the
    /// world-space path under the transform equals drawing it in the old
    /// transformed world layer.
    func testWirePathUnderAffineMatchesTransformedPoints() {
        for _ in 0..<200 {
            let t = randomTransform()
            let start = randomPoint(0...6000), end = randomPoint(0...6000)
            let dx = max(40, abs(end.x - start.x) * 0.5)
            let c1 = CGPoint(x: start.x + dx, y: start.y), c2 = CGPoint(x: end.x - dx, y: end.y)

            let path = CGMutablePath()
            path.move(to: start)
            path.addCurve(to: end, control1: c1, control2: c2)
            var affine = t.affine
            guard let screenPath = path.copy(using: &affine) else { return XCTFail("no path") }

            var points: [CGPoint] = []
            screenPath.applyWithBlock { element in
                let e = element.pointee
                switch e.type {
                case .moveToPoint: points.append(e.points[0])
                case .addCurveToPoint: points += [e.points[0], e.points[1], e.points[2]]
                default: break
                }
            }
            let expected = [start, c1, c2, end].map(t.screen)
            XCTAssertEqual(points.count, expected.count)
            for (a, b) in zip(points, expected) { assertClose(a, b, accuracy: 1e-6) }
        }
    }

    /// Strokes are drawn in world units under the transform, so on screen they
    /// are `lineWidth * scale` wide — the same look the old scaled world layer
    /// gave them.
    func testStrokeWidthScalesWithZoom() {
        for scale in [0.3, 0.75, 1, 1.5, 2.5] as [CGFloat] {
            let t = CanvasTransform(scale: scale, offset: CGSize(width: 123, height: -45))
            let width = CGSize(width: 1.8, height: 0).applying(t.affine).width
            XCTAssertEqual(width, 1.8 * scale, accuracy: 1e-9)
        }
    }

    func testPixelAlignedSnapsOnlyTheTranslation() {
        let t = CanvasTransform(scale: 1.37, offset: CGSize(width: 33.25, height: -91.75))
        let retina = t.pixelAligned(displayScale: 2)
        XCTAssertEqual(retina.scale, 1.37)
        XCTAssertEqual(retina.offset, CGSize(width: 33.5, height: -91.5)) // half up, also below 0
        XCTAssertEqual(t.pixelAligned(displayScale: 1).offset, CGSize(width: 33, height: -92))
        let aligned = CanvasTransform(scale: 2, offset: CGSize(width: 10.5, height: -3))
        XCTAssertEqual(aligned.pixelAligned(displayScale: 2), aligned)
        XCTAssertEqual(t.pixelAligned(displayScale: 0), t)
    }

    func testDrawingTransformIsThePixelAlignedAffine() {
        let t = CanvasTransform(scale: 0.73, offset: CGSize(width: -91.75, height: 13.1))
        let drawing = t.drawingTransform(displayScale: 2)
        XCTAssertEqual(drawing, t.pixelAligned(displayScale: 2).affine)
        XCTAssertEqual(drawing.tx, -91.5)
        XCTAssertEqual(drawing.ty, 13.0)
        XCTAssertEqual(drawing.a, 0.73)
        XCTAssertEqual(drawing.d, 0.73)
    }

    func testZoomMatchesLegacyAndKeepsAnchorFixed() {
        for _ in 0..<500 {
            let t = randomTransform()
            let anchor = randomPoint(0...2000)
            let factor = CGFloat.random(in: 0.5...1.6, using: &rng)
            let zoomed = t.zoomed(by: factor, around: anchor)
            let (scale, offset) = Legacy.zoom(scale: t.scale, offset: t.offset,
                                              by: factor, around: anchor)
            XCTAssertEqual(zoomed.scale, scale)
            XCTAssertEqual(zoomed.offset, offset)
            assertClose(zoomed.world(anchor), t.world(anchor), accuracy: 1e-6)
        }
    }

    func testZoomClamps() {
        let t = CanvasTransform(scale: 2, offset: .zero)
        XCTAssertEqual(t.zoomed(by: 10, around: .zero).scale, 2.5)
        XCTAssertEqual(t.zoomed(by: 0.01, around: .zero).scale, 0.3)
    }

    func testFittingMatchesLegacy() {
        for _ in 0..<500 {
            let minX = CGFloat.random(in: -500...3000, using: &rng)
            let minY = CGFloat.random(in: -500...3000, using: &rng)
            let maxX = minX + .random(in: 0...3000, using: &rng)
            let maxY = minY + .random(in: 0...3000, using: &rng)
            let view = CGSize(width: .random(in: 2...3000, using: &rng),
                              height: .random(in: 2...2000, using: &rng))
            let fit = CanvasTransform.fitting(
                CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), in: view)
            let legacy = Legacy.fit(minX: minX, minY: minY, maxX: maxX, maxY: maxY, viewSize: view)
            XCTAssertNotNil(fit)
            XCTAssertEqual(fit?.scale ?? 0, legacy?.0 ?? -1, accuracy: 1e-9)
            XCTAssertEqual(fit?.offset.width ?? 0, legacy?.1.width ?? -1, accuracy: 1e-6)
            XCTAssertEqual(fit?.offset.height ?? 0, legacy?.1.height ?? -1, accuracy: 1e-6)
        }
    }

    func testFittingRefusesAnUnlaidOutViewport() {
        let content = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertNil(CanvasTransform.fitting(content, in: .zero))
        XCTAssertNil(CanvasTransform.fitting(content, in: CGSize(width: 1, height: 800)))
        XCTAssertNil(CanvasTransform.fitting(content, in: CGSize(width: 800, height: -20)))
    }
}
