#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 4,
      let pixelSize = Int(CommandLine.arguments[3]),
      pixelSize > 0 else {
    fputs(
        "usage: make-app-icon.swift SOURCE_PNG OUTPUT_PNG PIXEL_SIZE\n",
        stderr
    )
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("Could not read source image.\n", stderr)
    exit(1)
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize,
    pixelsHigh: pixelSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not create icon bitmap.\n", stderr)
    exit(1)
}

bitmap.size = NSSize(width: pixelSize, height: pixelSize)
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create drawing context.\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
NSColor.clear.setFill()
canvas.fill()

// Keep the generated artwork intact while replacing its opaque white corners
// with the transparent rounded perimeter expected of a modern macOS icon.
let inset = CGFloat(pixelSize) * 0.012
let iconRect = canvas.insetBy(dx: inset, dy: inset)
let cornerRadius = CGFloat(pixelSize) * 0.215
NSBezierPath(
    roundedRect: iconRect,
    xRadius: cornerRadius,
    yRadius: cornerRadius
).addClip()

source.draw(
    in: canvas,
    from: NSRect(origin: .zero, size: source.size),
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode icon PNG.\n", stderr)
    exit(1)
}

do {
    try png.write(to: outputURL, options: .atomic)
} catch {
    fputs("Could not write icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
