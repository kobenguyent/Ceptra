#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift generate-icon.swift <output-icns-path>\n", stderr)
    exit(1)
}

let outputIcnsPath = CommandLine.arguments[1]
let outputURL = URL(fileURLWithPath: outputIcnsPath)
let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ceptra-icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = tempDir.appendingPathComponent("Ceptra.iconset", isDirectory: true)

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDir) }

func renderIconPNG(pixelSize: Int) -> Data? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let s = CGFloat(pixelSize)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // macOS standard icon safe-area inset (~9.6%)
    let margin = s * 0.096
    let cardRect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let cornerRadius = cardRect.width * 0.225
    let squircle = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Soft Dock drop shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.015),
        blur: s * 0.028,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)
    )
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Clipped obsidian studio body
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let bgColors = [
        CGColor(red: 0.105, green: 0.125, blue: 0.195, alpha: 1.0),
        CGColor(red: 0.055, green: 0.064, blue: 0.102, alpha: 1.0)
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }

    // Ambient indigo radial illumination
    let glowColors = [
        CGColor(red: 0.36, green: 0.56, blue: 1.0, alpha: 0.34),
        CGColor(red: 0.36, green: 0.56, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let radial = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            radial,
            startCenter: CGPoint(x: s * 0.5, y: s * 0.56),
            startRadius: s * 0.03,
            endCenter: CGPoint(x: s * 0.5, y: s * 0.56),
            endRadius: s * 0.44,
            options: []
        )
    }

    // Subtle geometric grid accent lines
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.04))
    ctx.setLineWidth(max(1.0, s * 0.004))
    for i in 1...3 {
        let offset = cardRect.minX + cardRect.width * (CGFloat(i) / 4.0)
        ctx.move(to: CGPoint(x: offset, y: cardRect.minY))
        ctx.addLine(to: CGPoint(x: offset, y: cardRect.maxY))
        let yOffset = cardRect.minY + cardRect.height * (CGFloat(i) / 4.0)
        ctx.move(to: CGPoint(x: cardRect.minX, y: yOffset))
        ctx.addLine(to: CGPoint(x: cardRect.maxX, y: yOffset))
    }
    ctx.strokePath()

    // Open C-arc (Ceptra / CodeceptJS monogram)
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let radius = s * 0.245
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: s * 0.035,
        color: CGColor(red: 0.38, green: 0.58, blue: 1.0, alpha: 0.55)
    )
    ctx.setLineCap(.round)
    ctx.setLineWidth(s * 0.060)
    ctx.setStrokeColor(CGColor(red: 0.44, green: 0.62, blue: 1.0, alpha: 1.0))
    ctx.addArc(
        center: center,
        radius: radius,
        startAngle: CGFloat.pi * 0.23,
        endAngle: CGFloat.pi * 1.77,
        clockwise: false
    )
    ctx.strokePath()
    ctx.restoreGState()

    // Emerald execution play triangle
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: s * 0.03,
        color: CGColor(red: 0.22, green: 0.88, blue: 0.60, alpha: 0.55)
    )
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: s * 0.455, y: s * 0.395))
    tri.addLine(to: CGPoint(x: s * 0.655, y: s * 0.50))
    tri.addLine(to: CGPoint(x: s * 0.455, y: s * 0.605))
    tri.closeSubpath()
    ctx.addPath(tri)
    ctx.setFillColor(CGColor(red: 0.24, green: 0.86, blue: 0.60, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState()

    // Fine top-lit rim stroke
    ctx.addPath(squircle)
    ctx.setLineWidth(max(1.0, s * 0.011))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    ctx.strokePath()

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in sizes {
    guard let data = renderIconPNG(pixelSize: px) else {
        fputs("Failed to render icon size \(px)\n", stderr)
        exit(1)
    }
    try data.write(to: iconsetURL.appendingPathComponent(filename))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try proc.run()
proc.waitUntilExit()

if proc.terminationStatus != 0 {
    fputs("iconutil failed with exit code \(proc.terminationStatus)\n", stderr)
    exit(proc.terminationStatus)
}
