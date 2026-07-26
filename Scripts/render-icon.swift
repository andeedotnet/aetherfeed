// Renders the app icon (1024×1024 PNG) without Xcode/asset catalog:
//   swift Scripts/render-icon.swift <output.png>
import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/icon-1024.png"

let canvas = 1024.0
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// macOS icon grid: tile with margin, strongly rounded corners.
let inset = canvas * 0.098
let tile = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let radius = tile.width * 0.225
let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

// Subtle shadow under the tile.
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.008)
shadow.shadowBlurRadius = canvas * 0.02
shadow.set()
NSColor.white.setFill()
tilePath.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// Gradient blue → violet.
let gradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.14, green: 0.44, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.52, green: 0.22, blue: 0.94, alpha: 1),
    ]
)!
gradient.draw(in: tilePath, angle: -60)

// Radio-waves symbol in white, centered.
func tinted(_ source: NSImage, color: NSColor) -> NSImage {
    NSImage(size: source.size, flipped: false) { rect in
        source.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold)
if let symbol = NSImage(
    systemSymbolName: "dot.radiowaves.up.forward", accessibilityDescription: nil
)?.withSymbolConfiguration(config) {
    let white = tinted(symbol, color: .white)
    let scale = (tile.width * 0.62) / max(white.size.width, white.size.height)
    let drawSize = NSSize(
        width: white.size.width * scale, height: white.size.height * scale)
    let origin = NSPoint(
        x: tile.midX - drawSize.width / 2,
        y: tile.midY - drawSize.height / 2
    )
    white.draw(
        in: NSRect(origin: origin, size: drawSize),
        from: .zero, operation: .sourceOver, fraction: 1)
}

// Sparkle at the top right as a nod to the AI enrichment.
let sparkleConfig = NSImage.SymbolConfiguration(pointSize: 160, weight: .bold)
if let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
    .withSymbolConfiguration(sparkleConfig) {
    let white = tinted(sparkle, color: NSColor.white.withAlphaComponent(0.92))
    let side = tile.width * 0.17
    let rect = NSRect(
        x: tile.maxX - side - tile.width * 0.14,
        y: tile.maxY - side - tile.width * 0.13,
        width: side, height: side)
    white.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fatalError("PNG-Erzeugung fehlgeschlagen")
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("OK: \(outputPath)")
