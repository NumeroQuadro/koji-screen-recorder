#!/usr/bin/env swift
//
// generate_menubar_icons.swift
// Generates menu bar template images for Kōji (idle and recording states).
//
// Usage: swift scripts/generate_menubar_icons.swift
//
// Output:
//   Sources/Resources/Assets.xcassets/MenuBarIcon.imageset/
//   Sources/Resources/Assets.xcassets/MenuBarIconRecording.imageset/
//

import Foundation
import AppKit

// MARK: - Configuration

let iconSize: CGFloat = 22.0  // Standard menu bar icon height
let exportSizes: [(CGFloat, String)] = [
    (1.0, ""),
    (2.0, "@2x"),
    (3.0, "@3x"),
]

// MARK: - Drawing

/// Draws the idle menu bar icon: a display/screen with small recording dot
func renderIdleIcon(size: CGFloat, scale: CGFloat) -> NSImage {
    let pixelSize = size * scale
    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
    image.lockFocus()

    guard let _ = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = pixelSize
    let padding = s * 0.08

    // Screen body (rounded rect)
    let screenRect = CGRect(
        x: padding,
        y: s * 0.25,
        width: s - padding * 2,
        height: s * 0.55
    )
    let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: s * 0.06, yRadius: s * 0.06)
    NSColor.black.setStroke()
    screenPath.lineWidth = max(1.0, s * 0.06)
    screenPath.stroke()

    // Screen stand
    let standWidth = s * 0.25
    let standPath = NSBezierPath()
    standPath.move(to: NSPoint(x: s / 2 - standWidth / 2, y: s * 0.15))
    standPath.line(to: NSPoint(x: s / 2 + standWidth / 2, y: s * 0.15))
    standPath.lineWidth = max(1.0, s * 0.06)
    NSColor.black.setStroke()
    standPath.stroke()

    // Stand leg
    let legPath = NSBezierPath()
    legPath.move(to: NSPoint(x: s / 2, y: s * 0.15))
    legPath.line(to: NSPoint(x: s / 2, y: s * 0.25))
    legPath.lineWidth = max(1.0, s * 0.06)
    NSColor.black.setStroke()
    legPath.stroke()

    // Small recording dot in center of screen
    let dotRadius = s * 0.07
    let dotCenter = CGPoint(x: s / 2, y: s * 0.52)
    let dotRect = CGRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )
    NSColor.black.setFill()
    let dotPath = NSBezierPath(ovalIn: dotRect)
    dotPath.fill()

    image.unlockFocus()
    return image
}

/// Draws the recording menu bar icon: filled circle with recording indicator
func renderRecordingIcon(size: CGFloat, scale: CGFloat) -> NSImage {
    let pixelSize = size * scale
    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
    image.lockFocus()

    let s = pixelSize
    let padding = s * 0.08

    // Screen body filled
    let screenRect = CGRect(
        x: padding,
        y: s * 0.25,
        width: s - padding * 2,
        height: s * 0.55
    )
    let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: s * 0.06, yRadius: s * 0.06)
    NSColor.black.setFill()
    screenPath.fill()

    // Screen stand
    let standWidth = s * 0.25
    let standPath = NSBezierPath()
    standPath.move(to: NSPoint(x: s / 2 - standWidth / 2, y: s * 0.15))
    standPath.line(to: NSPoint(x: s / 2 + standWidth / 2, y: s * 0.15))
    standPath.lineWidth = max(1.0, s * 0.06)
    NSColor.black.setStroke()
    standPath.stroke()

    // Stand leg
    let legPath = NSBezierPath()
    legPath.move(to: NSPoint(x: s / 2, y: s * 0.15))
    legPath.line(to: NSPoint(x: s / 2, y: s * 0.25))
    legPath.lineWidth = max(1.0, s * 0.06)
    NSColor.black.setStroke()
    legPath.stroke()

    // Recording dot (white/clear cutout in center)
    let dotRadius = s * 0.09
    let dotCenter = CGPoint(x: s / 2, y: s * 0.52)
    let dotRect = CGRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )
    // Use clear to punch a hole, or white for template
    NSColor.white.setFill()
    let dotPath = NSBezierPath(ovalIn: dotRect)
    dotPath.fill()

    image.unlockFocus()
    return image
}

// MARK: - Export

func savePNG(_ image: NSImage, to url: URL) {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("❌ Failed to export \(url.lastPathComponent)")
        return
    }

    do {
        try pngData.write(to: url)
        print("✅ Exported: \(url.lastPathComponent)")
    } catch {
        print("❌ Failed to write \(url.path): \(error)")
    }
}

func writeContentsJSON(to dir: URL, baseName: String, isTemplate: Bool) {
    var images: [[String: Any]] = []

    for (scale, suffix) in exportSizes {
        let scaleStr = "\(Int(scale))x"
        let filename = "\(baseName)\(suffix).png"
        images.append([
            "filename": filename,
            "idiom": "mac",
            "scale": scaleStr,
        ])
    }

    var properties: [String: Any] = [:]
    if isTemplate {
        properties["template-rendering-intent"] = "template"
    }

    let contentsJSON: [String: Any] = [
        "images": images,
        "info": [
            "author": "xcode",
            "version": 1
        ],
        "properties": properties
    ]

    let contentsURL = dir.appendingPathComponent("Contents.json")
    if let jsonData = try? JSONSerialization.data(withJSONObject: contentsJSON, options: [.prettyPrinted, .sortedKeys]) {
        try? jsonData.write(to: contentsURL)
        print("✅ Wrote \(dir.lastPathComponent)/Contents.json")
    }
}

// MARK: - Main

func main() {
    let scriptDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
    let projectRoot = scriptDir.deletingLastPathComponent()
    let assetsDir = projectRoot.appendingPathComponent("Sources/Resources/Assets.xcassets")

    let fm = FileManager.default

    // --- Idle icon ---
    let idleDir = assetsDir.appendingPathComponent("MenuBarIcon.imageset")
    try? fm.createDirectory(at: idleDir, withIntermediateDirectories: true)

    print("🖼  Generating idle menu bar icon...")
    for (scale, suffix) in exportSizes {
        let icon = renderIdleIcon(size: iconSize, scale: scale)
        let filename = "menubar_idle\(suffix).png"
        savePNG(icon, to: idleDir.appendingPathComponent(filename))
    }
    writeContentsJSON(to: idleDir, baseName: "menubar_idle", isTemplate: true)

    // --- Recording icon ---
    let recDir = assetsDir.appendingPathComponent("MenuBarIconRecording.imageset")
    try? fm.createDirectory(at: recDir, withIntermediateDirectories: true)

    print("🖼  Generating recording menu bar icon...")
    for (scale, suffix) in exportSizes {
        let icon = renderRecordingIcon(size: iconSize, scale: scale)
        let filename = "menubar_recording\(suffix).png"
        savePNG(icon, to: recDir.appendingPathComponent(filename))
    }
    writeContentsJSON(to: recDir, baseName: "menubar_recording", isTemplate: true)

    print("\n🎉 Menu bar icon generation complete!")
}

main()
