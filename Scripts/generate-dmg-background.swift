#!/usr/bin/env swift

import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-dmg-background.swift OUTPUT.png\n", stderr)
    exit(2)
}

let size = NSSize(width: 720, height: 460)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create the DMG background canvas.\n", stderr)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let bounds = NSRect(origin: .zero, size: size)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.96, green: 0.94, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.93, green: 0.97, blue: 1.0, alpha: 1),
    NSColor.white
])!
gradient.draw(in: bounds, angle: -18)

let glow = NSBezierPath(ovalIn: NSRect(x: 228, y: 118, width: 264, height: 180))
NSColor(calibratedRed: 0.52, green: 0.27, blue: 0.96, alpha: 0.07).setFill()
glow.fill()

let centered = NSMutableParagraphStyle()
centered.alignment = .center

let title = "Install WhisperType" as NSString
title.draw(in: NSRect(x: 60, y: 380, width: 600, height: 42), withAttributes: [
    .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.13, alpha: 1),
    .paragraphStyle: centered
])

let subtitle = "Drag WhisperType to Applications" as NSString
subtitle.draw(in: NSRect(x: 60, y: 346, width: 600, height: 28), withAttributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.38, alpha: 1),
    .paragraphStyle: centered
])

let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 310, y: 218))
arrow.line(to: NSPoint(x: 410, y: 218))
arrow.move(to: NSPoint(x: 387, y: 240))
arrow.line(to: NSPoint(x: 410, y: 218))
arrow.line(to: NSPoint(x: 387, y: 196))
NSColor(calibratedRed: 0.55, green: 0.18, blue: 0.91, alpha: 0.72).setStroke()
arrow.stroke()

let footnote = "Keep WhisperType in Applications so macOS permissions and updates work reliably." as NSString
footnote.draw(in: NSRect(x: 90, y: 42, width: 540, height: 36), withAttributes: [
    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.47, alpha: 1),
    .paragraphStyle: centered
])

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not render the DMG background.\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
