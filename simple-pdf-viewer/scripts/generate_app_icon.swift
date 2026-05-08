import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift /path/to/source.png /path/to/output.png\n", stderr)
    exit(1)
}

let sourcePath = arguments[0]
let outputPath = arguments[1]

guard let sourceImage = NSImage(contentsOfFile: sourcePath) else {
    fputs("failed to load source image: \(sourcePath)\n", stderr)
    exit(1)
}

let canvasSize = CGSize(width: 1024, height: 1024)
let image = NSImage(size: canvasSize)

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

image.lockFocus()

let backdropShadow = NSShadow()
backdropShadow.shadowBlurRadius = 30
backdropShadow.shadowOffset = CGSize(width: 0, height: -14)
backdropShadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.14)

NSGraphicsContext.current?.saveGraphicsState()
backdropShadow.set()
let backdrop = roundedRect(NSRect(x: 166, y: 164, width: 692, height: 692), radius: 168)
let backdropGradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.22, alpha: 0.92),
        NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.17, alpha: 0.92),
    ]
)!
backdropGradient.draw(in: backdrop, angle: 90)
NSGraphicsContext.current?.restoreGraphicsState()

NSColor(calibratedWhite: 1.0, alpha: 0.10).setStroke()
backdrop.lineWidth = 2
backdrop.stroke()

let halo = NSBezierPath(ovalIn: NSRect(x: 212, y: 236, width: 600, height: 600))
let haloGradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.24, green: 0.88, blue: 0.88, alpha: 0.13),
        NSColor(calibratedRed: 0.16, green: 0.57, blue: 0.95, alpha: 0.06),
    ]
)!
haloGradient.draw(in: halo, relativeCenterPosition: .zero)

let plateShadow = NSShadow()
plateShadow.shadowBlurRadius = 22
plateShadow.shadowOffset = CGSize(width: 0, height: -10)
plateShadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.10)

NSGraphicsContext.current?.saveGraphicsState()
plateShadow.set()
let documentBack = roundedRect(NSRect(x: 286, y: 260, width: 406, height: 472), radius: 62)
NSColor(calibratedRed: 0.92, green: 0.98, blue: 1.0, alpha: 0.56).setFill()
documentBack.fill()
NSGraphicsContext.current?.restoreGraphicsState()

let documentFront = roundedRect(NSRect(x: 326, y: 292, width: 360, height: 418), radius: 48)
let documentFrontGradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.15, green: 0.86, blue: 0.80, alpha: 0.78),
        NSColor(calibratedRed: 0.10, green: 0.79, blue: 0.75, alpha: 0.78),
    ]
)!
documentFrontGradient.draw(in: documentFront, angle: 90)

NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
documentFront.lineWidth = 3
documentFront.stroke()

let sourceShadow = NSShadow()
sourceShadow.shadowBlurRadius = 22
sourceShadow.shadowOffset = CGSize(width: 0, height: -10)
sourceShadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.20)

NSGraphicsContext.current?.saveGraphicsState()
sourceShadow.set()
sourceImage.draw(
    in: NSRect(x: 104, y: 116, width: 816, height: 816),
    from: .zero,
    operation: .sourceOver,
    fraction: 1.0
)
NSGraphicsContext.current?.restoreGraphicsState()

let badge = roundedRect(NSRect(x: 714, y: 188, width: 124, height: 124), radius: 38)
let badgeGradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.34, alpha: 1.0),
        NSColor(calibratedRed: 1.0, green: 0.66, blue: 0.18, alpha: 1.0),
    ]
)!
badgeGradient.draw(in: badge, angle: -45)

let pencil = NSBezierPath()
pencil.move(to: NSPoint(x: 750, y: 214))
pencil.line(to: NSPoint(x: 796, y: 260))
pencil.lineWidth = 14
pencil.lineCapStyle = .round
NSColor.white.setStroke()
pencil.stroke()

let pencilTip = NSBezierPath()
pencilTip.move(to: NSPoint(x: 794, y: 258))
pencilTip.line(to: NSPoint(x: 810, y: 274))
pencilTip.lineWidth = 11
pencilTip.lineCapStyle = .round
NSColor(calibratedRed: 0.17, green: 0.30, blue: 0.64, alpha: 1.0).setStroke()
pencilTip.stroke()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("failed to encode png\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
