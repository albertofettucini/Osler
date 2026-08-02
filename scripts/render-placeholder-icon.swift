import AppKit
import CoreGraphics

// Renders the placeholder app icon (a tiny node-flow on a dark squircle) as a
// 1024x1024 PNG. Used by package-app.sh only when assets/AppIcon.png (a real
// logo) doesn't exist yet.
// Usage: swift render-placeholder-icon.swift <output.png>

guard CommandLine.arguments.count == 2 else {
    print("usage: render-placeholder-icon.swift <output.png>")
    exit(2)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

let size = 1024
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("failed to create context")
    exit(1)
}

func color(_ hex: UInt, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

// Background squircle with the standard macOS icon margin (~10%).
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: 1024 - margin * 2, height: 1024 - margin * 2)
let squircle = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

context.addPath(squircle)
context.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [color(0x232838), color(0x0D0E12)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100),
    options: []
)

// Three nodes wired left → middle-top / middle-bottom → right, echoing the
// canvas: teal input, violet + amber mid, blue output, accent wires.
struct Dot { let x: CGFloat; let y: CGFloat; let r: CGFloat; let fill: UInt }
let dots: [Dot] = [
    Dot(x: 275, y: 512, r: 74, fill: 0x3FB6A8), // input (teal)
    Dot(x: 512, y: 680, r: 74, fill: 0x9B7BFF), // agent (violet)
    Dot(x: 512, y: 344, r: 74, fill: 0xE0A64B), // condition (amber)
    Dot(x: 749, y: 512, r: 74, fill: 0x5A9BFF), // output (blue)
]

func wire(from a: Dot, to b: Dot) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: a.x, y: a.y))
    let dx = (b.x - a.x) * 0.55
    path.addCurve(
        to: CGPoint(x: b.x, y: b.y),
        control1: CGPoint(x: a.x + dx, y: a.y),
        control2: CGPoint(x: b.x - dx, y: b.y)
    )
    context.addPath(path)
    context.setStrokeColor(color(0x6E8BFF, 0.9))
    context.setLineWidth(26)
    context.setLineCap(.round)
    context.strokePath()
}

wire(from: dots[0], to: dots[1])
wire(from: dots[0], to: dots[2])
wire(from: dots[1], to: dots[3])
wire(from: dots[2], to: dots[3])

for dot in dots {
    let bounds = CGRect(x: dot.x - dot.r, y: dot.y - dot.r, width: dot.r * 2, height: dot.r * 2)
    // Soft halo, filled disc, dark ring so dots read at 16px.
    context.setFillColor(color(dot.fill, 0.28))
    context.fillEllipse(in: bounds.insetBy(dx: -26, dy: -26))
    context.setFillColor(color(dot.fill))
    context.fillEllipse(in: bounds)
    context.setStrokeColor(color(0x0D0E12, 0.85))
    context.setLineWidth(14)
    context.strokeEllipse(in: bounds)
}

guard let image = context.makeImage() else {
    print("failed to render")
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else {
    print("failed to encode png")
    exit(1)
}
try png.write(to: outputURL)
print("wrote \(outputURL.path)")
