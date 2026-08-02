import AppKit
import CoreImage
import Vision

// Turns a logo-on-background PNG into a symbol-only app icon:
// 1. Lifts the subject off the background with Vision (the same ML behind
//    Preview's "Copy Subject"), preserving soft glassy edges.
// 2. Crops to the symbol's alpha bounding box.
// 3. Centers it on a transparent 1024x1024 canvas at icon-friendly scale.
// Usage: swift extract-symbol-icon.swift <input.png> <output.png>

guard CommandLine.arguments.count == 3 else {
    print("usage: extract-symbol-icon.swift <input.png> <output.png>")
    exit(2)
}
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = NSImage(contentsOf: inputURL),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("failed to read \(inputURL.path)")
    exit(1)
}

// ── 1. Subject lift ─────────────────────────────────────────────────────────
let handler = VNImageRequestHandler(cgImage: sourceCG, options: [:])
let request = VNGenerateForegroundInstanceMaskRequest()
try handler.perform([request])
guard let observation = request.results?.first else {
    print("Vision found no subject to lift")
    exit(1)
}
let maskedBuffer = try observation.generateMaskedImage(
    ofInstances: observation.allInstances,
    from: handler,
    croppedToInstancesExtent: false
)

let ciImage = CIImage(cvPixelBuffer: maskedBuffer)
let ciContext = CIContext()
guard let liftedCG = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
    print("failed to render lifted subject")
    exit(1)
}

// ── 2. Alpha bounding box ───────────────────────────────────────────────────
let width = liftedCG.width
let height = liftedCG.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let bboxContext = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("failed to create bbox context")
    exit(1)
}
bboxContext.draw(liftedCG, in: CGRect(x: 0, y: 0, width: width, height: height))

var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX >= minX, maxY >= minY else {
    print("subject mask is empty")
    exit(1)
}

// ── 2b. Hollow out enclosed background ──────────────────────────────────────
// Subject lifting keeps regions the symbol encloses (here: the pale area
// inside the wire triangle). Flood-fill from the symbol's centre, walking only
// bright low-saturation pixels, and fade them out. The darker wire bounds the
// fill; sphere highlights are unreachable behind saturated colour, so they
// keep their shine.
func backgroundStrength(_ index: Int) -> CGFloat {
    let alpha = CGFloat(pixels[index + 3])
    guard alpha > 0 else { return 0 }
    // Un-premultiply before judging brightness.
    let r = CGFloat(pixels[index]) * 255 / alpha
    let g = CGFloat(pixels[index + 1]) * 255 / alpha
    let b = CGFloat(pixels[index + 2]) * 255 / alpha
    let lo = min(r, g, b), hi = max(r, g, b)
    let brightness = min(max((lo - 175) / 55, 0), 1)      // 175…230 → 0…1
    let grayness = min(max((55 - (hi - lo)) / 45, 0), 1)  // sat 55…10 → 0…1
    return brightness * grayness
}

var queue: [Int] = []
var queued = [Bool](repeating: false, count: width * height)
let centerX = (minX + maxX) / 2, centerY = (minY + maxY) / 2
let spanX = maxX - minX, spanY = maxY - minY
for dy in [-spanY / 8, 0, spanY / 8] {
    for dx in [-spanX / 8, 0, spanX / 8] {
        let x = centerX + dx, y = centerY + dy
        guard x >= 0, x < width, y >= 0, y < height else { continue }
        let pixel = y * width + x
        if !queued[pixel], backgroundStrength(pixel * 4) > 0.3 {
            queued[pixel] = true
            queue.append(pixel)
        }
    }
}
var head = 0
while head < queue.count {
    let pixel = queue[head]
    head += 1
    let index = pixel * 4
    let strength = backgroundStrength(index)
    guard strength > 0.12 else { continue }
    let keep = 1 - strength
    for channel in 0..<4 { // premultiplied: scale colour with alpha
        pixels[index + channel] = UInt8(CGFloat(pixels[index + channel]) * keep)
    }
    let x = pixel % width, y = pixel / width
    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
        let neighbor = ny * width + nx
        if !queued[neighbor] {
            queued[neighbor] = true
            queue.append(neighbor)
        }
    }
}

guard let hollowedCG = bboxContext.makeImage() else {
    print("failed to rebuild hollowed image")
    exit(1)
}
let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
guard let cropped = hollowedCG.cropping(to: cropRect) else {
    print("failed to crop")
    exit(1)
}

// ── 3. Compose the 1024 icon ────────────────────────────────────────────────
let canvas = 1024
// How much of the canvas the symbol's longest side occupies. Near full-bleed
// so the mark reads big next to other icons; a sliver of margin avoids clipping.
let contentSpan: CGFloat = 990
let scale = min(contentSpan / CGFloat(cropRect.width), contentSpan / CGFloat(cropRect.height))
let drawWidth = CGFloat(cropRect.width) * scale
let drawHeight = CGFloat(cropRect.height) * scale

guard let iconContext = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("failed to create icon context")
    exit(1)
}
iconContext.interpolationQuality = .high
iconContext.draw(cropped, in: CGRect(
    x: (CGFloat(canvas) - drawWidth) / 2,
    y: (CGFloat(canvas) - drawHeight) / 2,
    width: drawWidth,
    height: drawHeight
))

guard let iconImage = iconContext.makeImage() else {
    print("failed to render icon")
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: iconImage)
guard let png = rep.representation(using: .png, properties: [:]) else {
    print("failed to encode png")
    exit(1)
}
try png.write(to: outputURL)
print("wrote \(outputURL.path)")
