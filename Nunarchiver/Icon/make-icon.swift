// Draws Nunarchiver's app icon: a disk drive with flames behind it, on a macOS icon tile.
//
//   swift Icon/make-icon.swift Nunarchiver/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// One 1024×1024 PNG (the asset catalog's single-size macOS icon). Everything is drawn here with CoreGraphics:
// no assets. The tile is macOS's icon shape: 824×824 centered in the canvas, corner radius 185, with a soft shadow.
// Coordinates are in the 1024 canvas, y up.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift OUTPUT.png\n".utf8))
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let canvas = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("can't make a bitmap context\n".utf8))
    exit(1)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ]
    )!
}

/// Fills `path` with a linear gradient from `start` to `end`.
func fill(_ path: CGPath, _ colors: [CGColor], locations: [CGFloat]? = nil, from start: CGPoint, to end: CGPoint) {
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A flame tongue: a teardrop standing on `base` (its bottom center), `width` across at its widest, its tip
/// `height` above the base and `lean` to the right of it.
func flame(base: CGPoint, width: CGFloat, height: CGFloat, lean: CGFloat) -> CGPath {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }
    let half = width / 2
    let path = CGMutablePath()
    path.move(to: point(0, -height * 0.04))
    // Left side: out to the belly, then in to the tip, arriving from below and a little from the left.
    path.addCurve(
        to: point(-half, height * 0.30),
        control1: point(-half * 0.60, -height * 0.04), control2: point(-half, height * 0.10)
    )
    path.addCurve(
        to: point(lean, height),
        control1: point(-half, height * 0.58), control2: point(lean * 0.2 - half * 0.10, height * 0.70)
    )
    // Right side: the tip's hook, then the belly.
    path.addCurve(
        to: point(half, height * 0.30),
        control1: point(lean * 0.9 + half * 0.25, height * 0.74), control2: point(half, height * 0.56)
    )
    path.addCurve(
        to: point(0, -height * 0.04),
        control1: point(half, height * 0.10), control2: point(half * 0.60, -height * 0.04)
    )
    path.closeSubpath()
    return path
}

// MARK: Tile

let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = roundedRect(tileRect, radius: 185)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x000000, 0.32))
context.addPath(tile)
context.setFillColor(color(0x1B1F33))
context.fillPath()
context.restoreGState()

// Night blue at the top, warming toward the bottom.
fill(
    tile, [color(0x3A2A4E), color(0x232846), color(0x141A30)], locations: [0, 0.45, 1],
    from: CGPoint(x: 512, y: tileRect.minY), to: CGPoint(x: 512, y: tileRect.maxY)
)

context.saveGState()
context.addPath(tile)
context.clip()

// The fire's glow on the tile.
let glow = CGGradient(
    colorsSpace: space, colors: [color(0xFF7A1A, 0.55), color(0xFF5A10, 0.18), color(0xFF5A10, 0)] as CFArray,
    locations: [0, 0.55, 1]
)!
context.drawRadialGradient(
    glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 430,
    options: []
)

// MARK: Flames

// Three tongues (left, right, then the tall middle one over them), each in three layers: red-orange outside,
// orange-yellow inside, a pale core. They stand behind the disk, which hides their bases.
struct Tongue {
    var x: CGFloat, width: CGFloat, height: CGFloat, lean: CGFloat
}

let baseline: CGFloat = 430
let tongues = [
    Tongue(x: 366, width: 244, height: 330, lean: -52),
    Tongue(x: 660, width: 244, height: 290, lean: 58),
    Tongue(x: 512, width: 340, height: 450, lean: 44),
]
let layers: [(scale: CGFloat, colors: [CGColor])] = [
    (1.00, [color(0xFF6A00), color(0xFF3B1F), color(0xE8261C)]),
    (0.70, [color(0xFFD23A), color(0xFFA412), color(0xFF7A0A)]),
    (0.42, [color(0xFFF7C2), color(0xFFE566), color(0xFFC62E)]),
]

for layer in layers {
    for tongue in tongues {
        let path = flame(
            base: CGPoint(x: tongue.x, y: baseline),
            width: tongue.width * layer.scale, height: tongue.height * layer.scale, lean: tongue.lean * layer.scale
        )
        fill(
            path, layer.colors,
            from: CGPoint(x: tongue.x, y: baseline),
            to: CGPoint(x: tongue.x, y: baseline + tongue.height * layer.scale)
        )
    }
}

// MARK: Disk

let disk = CGRect(x: 212, y: 232, width: 600, height: 282)
let diskPath = roundedRect(disk, radius: 64)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.45))
context.addPath(diskPath)
context.setFillColor(color(0xD0D2D8))
context.fillPath()
context.restoreGState()

fill(
    diskPath, [color(0xA9ACB6), color(0xD4D6DC), color(0xF4F5F7)], locations: [0, 0.4, 1],
    from: CGPoint(x: 512, y: disk.minY), to: CGPoint(x: 512, y: disk.maxY)
)

// The front panel: a darker band along the bottom, under a groove.
let band: CGFloat = 96
context.saveGState()
context.addPath(diskPath)
context.clip()
let bandRect = CGRect(x: disk.minX, y: disk.minY, width: disk.width, height: band)
fill(
    CGPath(rect: bandRect, transform: nil), [color(0x8C909C), color(0xB1B4BE)],
    from: CGPoint(x: 512, y: bandRect.minY), to: CGPoint(x: 512, y: bandRect.maxY)
)
context.setFillColor(color(0x6E727E))
context.fill(CGRect(x: disk.minX, y: disk.minY + band, width: disk.width, height: 7))
context.setFillColor(color(0xFFFFFF, 0.75))
context.fill(CGRect(x: disk.minX, y: disk.minY + band + 7, width: disk.width, height: 4))
// A highlight along the top edge.
context.setFillColor(color(0xFFFFFF, 0.9))
context.fill(CGRect(x: disk.minX, y: disk.maxY - 6, width: disk.width, height: 6))
context.restoreGState()

// The activity light, lit orange by all the work.
let light = CGRect(x: disk.maxX - 112, y: disk.minY + band / 2 - 19, width: 38, height: 38)
context.saveGState()
context.setShadow(offset: .zero, blur: 18, color: color(0xFF8A1E, 0.9))
context.setFillColor(color(0xFF9A2E))
context.fillEllipse(in: light)
context.restoreGState()
fill(
    CGPath(ellipseIn: light, transform: nil), [color(0xFF7A12), color(0xFFD26A)],
    from: CGPoint(x: light.midX, y: light.minY), to: CGPoint(x: light.midX, y: light.maxY)
)

context.restoreGState()

// A hairline of light inside the tile's top edge.
context.saveGState()
context.addPath(tile)
context.clip()
context.addPath(roundedRect(tileRect.insetBy(dx: 2, dy: 2), radius: 183))
context.setStrokeColor(color(0xFFFFFF, 0.10))
context.setLineWidth(4)
context.strokePath()
context.restoreGState()

// MARK: Write

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("can't write \(output.path)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("can't write \(output.path)\n".utf8))
    exit(1)
}
