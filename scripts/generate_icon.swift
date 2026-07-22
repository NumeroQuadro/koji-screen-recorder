#!/usr/bin/env swift
//
// generate_icon.swift
// Generates the Kōji app icon programmatically using CoreGraphics.
//
// Usage: swift scripts/generate_icon.swift
//
// Output:
//   Sources/Resources/Assets.xcassets/AppIcon.appiconset/*.png
//   Sources/Resources/AppIcon.icns
//

import Foundation
import CoreGraphics
import AppKit

// MARK: - Configuration

let masterSize: CGFloat = 1024

// Brand colors
let bgColorTop    = NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x2E/255.0, alpha: 1.0) // #1A1A2E
let bgColorBottom = NSColor(red: 0x10/255.0, green: 0x10/255.0, blue: 0x20/255.0, alpha: 1.0) // #101020
let recordRed     = NSColor(red: 0xE6/255.0, green: 0x39/255.0, blue: 0x46/255.0, alpha: 1.0) // #E63946
let arcColor      = NSColor(red: 0xE6/255.0, green: 0x39/255.0, blue: 0x46/255.0, alpha: 0.6)
let arcColorOuter = NSColor(red: 0xE6/255.0, green: 0x39/255.0, blue: 0x46/255.0, alpha: 0.3)

// Icon sizes required for macOS app icon
// Each entry: (pointSize, scale) → pixel size = pointSize * scale
let iconSizes: [(Int, Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (64, 1), (64, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
    (1024, 1),
]

// MARK: - Drawing

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let scale = size / masterSize

    // --- 1. Rounded-rect background with gradient ---
    let cornerRadius = size * 0.22 // macOS icon corner radius (~22%)
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Gradient fill
    let gradient = NSGradient(
        starting: bgColorTop,
        ending: bgColorBottom
    )!
    gradient.draw(in: bgPath, angle: -90)

    // Subtle inner border
    let borderColor = NSColor(white: 1.0, alpha: 0.06)
    borderColor.setStroke()
    bgPath.lineWidth = 2.0 * scale
    bgPath.stroke()

    // --- 2. Concentric arcs (audio waves) ---
    let center = CGPoint(x: size / 2, y: size / 2)

    // Outer arc (larger, more transparent)
    drawArc(ctx: ctx, center: center, radius: size * 0.38, lineWidth: 12 * scale,
            color: arcColorOuter, startAngle: -40, endAngle: 40)
    drawArc(ctx: ctx, center: center, radius: size * 0.38, lineWidth: 12 * scale,
            color: arcColorOuter, startAngle: 140, endAngle: 220)

    // Inner arc (smaller, more opaque)
    drawArc(ctx: ctx, center: center, radius: size * 0.30, lineWidth: 14 * scale,
            color: arcColor, startAngle: -35, endAngle: 35)
    drawArc(ctx: ctx, center: center, radius: size * 0.30, lineWidth: 14 * scale,
            color: arcColor, startAngle: 145, endAngle: 215)

    // --- 3. Recording dot with glow ---
    let dotRadius = size * 0.11

    // Glow layers (multiple concentric circles with decreasing opacity)
    for i in stride(from: 5, through: 1, by: -1) {
        let glowRadius = dotRadius + CGFloat(i) * 12.0 * scale
        let alpha = 0.06 * CGFloat(6 - i)
        let glowColor = NSColor(red: 0xE6/255.0, green: 0x39/255.0, blue: 0x46/255.0, alpha: alpha)
        let glowRect = CGRect(
            x: center.x - glowRadius,
            y: center.y - glowRadius,
            width: glowRadius * 2,
            height: glowRadius * 2
        )
        glowColor.setFill()
        let glowPath = NSBezierPath(ovalIn: glowRect)
        glowPath.fill()
    }

    // Main dot with radial gradient
    let dotRect = CGRect(
        x: center.x - dotRadius,
        y: center.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )

    // Radial gradient for the dot (bright center → deeper red at edge)
    let dotHighlight = NSColor(red: 0xFF/255.0, green: 0x5C/255.0, blue: 0x67/255.0, alpha: 1.0)
    let dotGradient = NSGradient(
        colors: [dotHighlight, recordRed],
        atLocations: [0.0, 1.0],
        colorSpace: .deviceRGB
    )!
    let dotPath = NSBezierPath(ovalIn: dotRect)
    dotGradient.draw(in: dotPath, relativeCenterPosition: NSPoint(x: -0.15, y: 0.15))

    // Specular highlight on the dot
    let highlightRadius = dotRadius * 0.4
    let highlightCenter = CGPoint(x: center.x - dotRadius * 0.2, y: center.y + dotRadius * 0.2)
    let highlightRect = CGRect(
        x: highlightCenter.x - highlightRadius,
        y: highlightCenter.y - highlightRadius,
        width: highlightRadius * 2,
        height: highlightRadius * 2
    )
    let highlightColor = NSColor(white: 1.0, alpha: 0.25)
    highlightColor.setFill()
    let highlightPath = NSBezierPath(ovalIn: highlightRect)
    highlightPath.fill()

    image.unlockFocus()
    return image
}

func drawArc(ctx: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat,
             color: NSColor, startAngle: CGFloat, endAngle: CGFloat) {
    ctx.saveGState()

    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle)
    path.lineWidth = lineWidth
    path.lineCapStyle = .round

    color.setStroke()
    path.stroke()

    ctx.restoreGState()
}

// MARK: - Export

func savePNG(_ image: NSImage, to url: URL, pixelSize: Int) {
    let targetSize = NSSize(width: pixelSize, height: pixelSize)
    let resizedImage = NSImage(size: targetSize)
    resizedImage.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: targetSize),
               from: NSRect(origin: .zero, size: image.size),
               operation: .copy, fraction: 1.0)
    resizedImage.unlockFocus()

    guard let tiffData = resizedImage.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("❌ Failed to export PNG for size \(pixelSize)")
        return
    }

    do {
        try pngData.write(to: url)
        print("✅ Exported: \(url.lastPathComponent) (\(pixelSize)×\(pixelSize))")
    } catch {
        print("❌ Failed to write \(url.path): \(error)")
    }
}

// MARK: - Main

func main() {
    let scriptDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
    let projectRoot = scriptDir.deletingLastPathComponent()

    // Output directories
    let iconsetDir = projectRoot
        .appendingPathComponent("Sources/Resources/Assets.xcassets/AppIcon.appiconset")
    let icnsOutputDir = projectRoot.appendingPathComponent("Sources/Resources")

    let fm = FileManager.default

    // Create iconset directory
    try? fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

    print("🎨 Generating Kōji app icon...")

    // Render master icon at 1024×1024
    let masterIcon = renderIcon(size: masterSize)

    // Export all sizes
    var contentsImages: [[String: Any]] = []

    for (pointSize, scaleFactor) in iconSizes {
        let pixelSize = pointSize * scaleFactor
        let scaleStr = "\(scaleFactor)x"
        let filename: String
        if scaleFactor == 1 {
            filename = "icon_\(pointSize)x\(pointSize).png"
        } else {
            filename = "icon_\(pointSize)x\(pointSize)@\(scaleStr).png"
        }

        let outputURL = iconsetDir.appendingPathComponent(filename)
        savePNG(masterIcon, to: outputURL, pixelSize: pixelSize)

        contentsImages.append([
            "filename": filename,
            "idiom": "mac",
            "scale": scaleStr,
            "size": "\(pointSize)x\(pointSize)"
        ])
    }

    // Write Contents.json for the appiconset
    let contentsJSON: [String: Any] = [
        "images": contentsImages,
        "info": [
            "author": "xcode",
            "version": 1
        ]
    ]

    let contentsJSONURL = iconsetDir.appendingPathComponent("Contents.json")
    if let jsonData = try? JSONSerialization.data(withJSONObject: contentsJSON, options: [.prettyPrinted, .sortedKeys]) {
        try? jsonData.write(to: contentsJSONURL)
        print("✅ Wrote Contents.json")
    }

    // Also create a temporary .iconset for iconutil conversion
    let tmpIconsetDir = fm.temporaryDirectory.appendingPathComponent("Koji.iconset")
    try? fm.removeItem(at: tmpIconsetDir)
    try? fm.createDirectory(at: tmpIconsetDir, withIntermediateDirectories: true)

    // iconutil expects specific names
    let iconutilSizes: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for (name, pixelSize) in iconutilSizes {
        let outputURL = tmpIconsetDir.appendingPathComponent(name)
        savePNG(masterIcon, to: outputURL, pixelSize: pixelSize)
    }

    // Run iconutil to convert .iconset → .icns
    let icnsOutput = icnsOutputDir.appendingPathComponent("AppIcon.icns")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["--convert", "icns", tmpIconsetDir.path, "--output", icnsOutput.path]

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            print("✅ Generated AppIcon.icns")
        } else {
            print("❌ iconutil failed with status \(process.terminationStatus)")
        }
    } catch {
        print("❌ iconutil error: \(error)")
    }

    // Clean up temp iconset
    try? fm.removeItem(at: tmpIconsetDir)

    print("\n🎉 Icon generation complete!")
    print("   Iconset: \(iconsetDir.path)")
    print("   ICNS:    \(icnsOutput.path)")
}

main()
