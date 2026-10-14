import CoreGraphics
import Observation
import XCTest
@testable import OslerGeometry

private final class Flag: @unchecked Sendable {
    var fired = false
}

@MainActor
final class CanvasViewportTests: XCTestCase {

    /// Registers a one-shot observation of whatever `read` touches.
    private func watch(_ read: () -> Void) -> Flag {
        let flag = Flag()
        withObservationTracking(read, onChange: { flag.fired = true })
        return flag
    }

    func testScreenWorldRoundTripThroughViewport() {
        let viewport = CanvasViewport(CanvasTransform(scale: 1.7, offset: CGSize(width: -320, height: 88)))
        for point in [CGPoint.zero, CGPoint(x: 120, y: 940), CGPoint(x: -55.5, y: 3999)] {
            let screen = viewport.worldToScreen(point)
            XCTAssertEqual(screen, viewport.transform.screen(point))
            let back = viewport.screenToWorld(screen)
            XCTAssertEqual(back.x, point.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
        }
    }

    func testPanAccumulatesScreenDeltas() {
        let viewport = CanvasViewport(CanvasTransform(scale: 0.5, offset: CGSize(width: 10, height: 20)))
        viewport.pan(by: CGSize(width: 3, height: -4))
        viewport.pan(by: CGSize(width: 7, height: 4))
        XCTAssertEqual(viewport.offset, CGSize(width: 20, height: 20))
        XCTAssertEqual(viewport.scale, 0.5)
    }

    func testZoomDelegatesToTransform() {
        let start = CanvasTransform(scale: 1.2, offset: CGSize(width: 40, height: -60))
        let viewport = CanvasViewport(start)
        let anchor = CGPoint(x: 500, y: 300)
        viewport.zoom(by: 1.3, around: anchor)
        XCTAssertEqual(viewport.transform, start.zoomed(by: 1.3, around: anchor))
    }

    // MARK: Invalidation — the whole point of the separate object

    /// A pan must not invalidate a view that only reads the scale (a node
    /// port's grab halo) — otherwise every card re-renders per scroll tick.
    func testPanDoesNotInvalidateScaleReaders() {
        let viewport = CanvasViewport()
        let scaleReader = watch { _ = viewport.scale }
        viewport.pan(by: CGSize(width: 12, height: 3))
        viewport.setOffset(CGSize(width: -800, height: 40))
        XCTAssertFalse(scaleReader.fired)
    }

    func testPanInvalidatesOffsetReaders() {
        let viewport = CanvasViewport()
        let offsetReader = watch { _ = viewport.offset }
        viewport.pan(by: CGSize(width: 12, height: 3))
        XCTAssertTrue(offsetReader.fired)
    }

    func testZoomInvalidatesScaleReaders() {
        let viewport = CanvasViewport()
        let scaleReader = watch { _ = viewport.scale }
        viewport.zoom(by: 1.25, around: CGPoint(x: 100, y: 100))
        XCTAssertTrue(scaleReader.fired)
    }

    /// Re-applying the same value (a pinch held at the zoom limit) is not a
    /// change and must not invalidate anything.
    func testUnchangedWritesDoNotInvalidate() {
        let viewport = CanvasViewport(CanvasTransform(scale: 2.5, offset: CGSize(width: 5, height: 5)))
        let reader = watch { _ = viewport.transform }
        viewport.zoom(by: 1.2, around: CGPoint(x: 5, y: 5)) // already at max; anchor fixed
        viewport.apply(viewport.transform)
        XCTAssertFalse(reader.fired)
    }
}
