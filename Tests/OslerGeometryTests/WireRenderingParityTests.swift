import CoreGraphics
import SwiftUI
import XCTest
@testable import OslerGeometry

/// Headless pixel check (ImageRenderer, no window) that moving the wires out
/// of the world container changes nothing on screen.
///
/// "Before" is the old structure: wires in a Canvas INSIDE the 6000×4000
/// world container, under `.scaleEffect(.topLeading)` + `.offset`, together
/// with the port dots. "After" is the new one: wires in a viewport-sized
/// Canvas drawing world paths through `CanvasTransform.pixelAligned().affine`,
/// port dots still in the transformed world container. Same picture means the
/// wires still meet the dots and the strokes still scale with the zoom.
@MainActor
final class WireRenderingParityTests: XCTestCase {
    private static let viewport = CGSize(width: 640, height: 420)
    private static let worldSize = CGSize(width: 6000, height: 4000)
    private static let displayScale: CGFloat = 2

    /// Output-port → input-port pairs, in world units (NodeGeometry-like).
    private static let wires: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 314, y: 249), CGPoint(x: 420, y: 249)),
        (CGPoint(x: 634, y: 235), CGPoint(x: 820, y: 400)),
        (CGPoint(x: 634, y: 267), CGPoint(x: 820, y: 120)),
        (CGPoint(x: 1034, y: 400), CGPoint(x: 900, y: 600)),
    ]

    private static func drawWires(_ context: GraphicsContext) {
        for (start, end) in wires {
            let dx = max(40, abs(end.x - start.x) * 0.5)
            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y),
                          control2: CGPoint(x: end.x - dx, y: end.y))
            context.stroke(path, with: .color(.black),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
        // The pending wire's dash pattern must scale the same way too.
        var pending = Path()
        pending.move(to: wires[0].0)
        pending.addLine(to: CGPoint(x: 700, y: 700))
        context.stroke(pending, with: .color(.red), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
    }

    private struct PortDots: View {
        var body: some View {
            ZStack(alignment: .topLeading) {
                ForEach(0..<WireRenderingParityTests.wires.count, id: \.self) { index in
                    let (start, end) = WireRenderingParityTests.wires[index]
                    ForEach([start, end], id: \.x) { point in
                        Circle().stroke(Color.blue, lineWidth: 1.4)
                            .frame(width: 12, height: 12)
                            .position(point)
                    }
                }
            }
        }
    }

    private struct Before: View {
        let transform: CanvasTransform
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.white
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in WireRenderingParityTests.drawWires(context) }
                    PortDots()
                }
                .frame(width: worldSize.width, height: worldSize.height, alignment: .topLeading)
                .scaleEffect(transform.scale, anchor: .topLeading)
                .offset(transform.offset)
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .clipped()
        }
    }

    private struct After: View {
        let transform: CanvasTransform
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.white
                Canvas { context, _ in
                    context.concatenate(transform.drawingTransform(displayScale: displayScale))
                    WireRenderingParityTests.drawWires(context)
                }
                .frame(width: viewport.width, height: viewport.height)
                ZStack(alignment: .topLeading) {
                    PortDots()
                }
                .frame(width: worldSize.width, height: worldSize.height, alignment: .topLeading)
                .scaleEffect(transform.scale, anchor: .topLeading)
                .offset(transform.offset)
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .clipped()
        }
    }

    private func rgba<V: View>(_ view: V) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = Self.displayScale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        return buffer
    }

    func testScreenSpaceWiresRenderLikeTheOldWorldLayer() throws {
        let transforms: [CanvasTransform] = [
            CanvasTransform(),
            CanvasTransform(scale: 0.42, offset: CGSize(width: 120, height: 40)),
            CanvasTransform(scale: 1.7, offset: CGSize(width: -380, height: -220)),
            CanvasTransform(scale: 2.5, offset: CGSize(width: -700, height: -500)),
            // Fractional offsets: what a trackpad pan actually produces.
            CanvasTransform(scale: 0.3, offset: CGSize(width: 333.3, height: 17.25)),
            CanvasTransform(scale: 1, offset: CGSize(width: 33.75, height: -13.25)),
            CanvasTransform(scale: 1.37, offset: CGSize(width: -91.75, height: 13.1)),
        ]
        for transform in transforms {
            let before = try rgba(Before(transform: transform))
            let after = try rgba(After(transform: transform))
            XCTAssertEqual(before.count, after.count)
            var ink = 0, differing = 0
            for i in stride(from: 0, to: min(before.count, after.count), by: 4) {
                if before[i] < 250 || before[i + 1] < 250 || before[i + 2] < 250 { ink += 1 }
                let delta = (0..<3).map { abs(Int(before[i + $0]) - Int(after[i + $0])) }.max() ?? 0
                if delta > 16 { differing += 1 }
            }
            XCTAssertGreaterThan(ink, 100, "nothing drawn for \(transform)")
            // Anti-aliasing may differ on a handful of edge pixels at most.
            XCTAssertLessThanOrEqual(Double(differing), Double(ink) * 0.005,
                                     "\(differing) of \(ink) ink pixels differ for \(transform)")
        }
    }
}
