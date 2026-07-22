#!/usr/bin/env swift
//
// generate_og_image.swift
// Generates the Open Graph image for the GitHub Pages landing page.
//
// Usage: swift scripts/generate_og_image.swift
//
// Output:
//   docs/og-image.png (1200×630)
//

import Foundation
import AppKit

// MARK: - Configuration

let width: CGFloat = 1200
let height: CGFloat = 630

let bgTop = CGColor(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x20 / 255.0, alpha: 1.0) // #101020
let bgBottom = CGColor(red: 0x0B / 255.0, green: 0x0B / 255.0, blue: 0x10 / 255.0, alpha: 1.0) // #0B0B10
let accent = CGColor(red: 0xE6 / 255.0, green: 0x39 / 255.0, blue: 0x46 / 255.0, alpha: 1.0) // #E63946
let titleWhite = CGColor(red: 0xF0 / 255.0, green: 0xF6 / 255.0, blue: 0xFC / 255.0, alpha: 0.95)
let subtitleGray = CGColor(red: 0xC7 / 255.0, green: 0xC9 / 255.0, blue: 0xD6 / 255.0, alpha: 0.70)

// MARK: - Drawing

func renderOGImage() -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        print("❌ Failed to create CGContext")
        return nil
    }

    // Background gradient
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [bgBottom, bgTop] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: width / 2, y: 0),
        end: CGPoint(x: width / 2, y: height),
        options: []
    )

    // Subtle dot grid texture
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.035))
    let dotSpacing: CGFloat = 26
    let dotRadius: CGFloat = 1.0
    var y: CGFloat = 18
    while y < height {
        var x: CGFloat = 18
        while x < width {
            ctx.fillEllipse(in: CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
            x += dotSpacing
        }
        y += dotSpacing
    }

    // Accent glow (radial)
    let glowGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0xE6 / 255.0, green: 0x39 / 255.0, blue: 0x46 / 255.0, alpha: 0.22),
            CGColor(red: 0xE6 / 255.0, green: 0x39 / 255.0, blue: 0x46 / 255.0, alpha: 0.00),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        glowGradient,
        startCenter: CGPoint(x: width * 0.22, y: height * 0.78),
        startRadius: 0,
        endCenter: CGPoint(x: width * 0.22, y: height * 0.78),
        endRadius: 420,
        options: []
    )

    // Title
    drawText(
        ctx: ctx,
        text: "KŌJI",
        x: width * 0.12,
        y: height * 0.62,
        fontSize: 120,
        fontWeight: .heavy,
        color: titleWhite,
        tracking: 6.0,
        alignment: .left
    )

    // Tagline (three lines)
    let line1Y = height * 0.46
    drawText(
        ctx: ctx,
        text: "Record your screen.",
        x: width * 0.12,
        y: line1Y,
        fontSize: 44,
        fontWeight: .semibold,
        color: subtitleGray,
        tracking: 0.6,
        alignment: .left
    )
    drawText(
        ctx: ctx,
        text: "Hear everything.",
        x: width * 0.12,
        y: line1Y - 56,
        fontSize: 44,
        fontWeight: .semibold,
        color: subtitleGray,
        tracking: 0.6,
        alignment: .left
    )
    drawText(
        ctx: ctx,
        text: "No drivers needed.",
        x: width * 0.12,
        y: line1Y - 112,
        fontSize: 44,
        fontWeight: .semibold,
        color: subtitleGray,
        tracking: 0.6,
        alignment: .left
    )

    // Accent underline
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 0xE6 / 255.0, green: 0x39 / 255.0, blue: 0x46 / 255.0, alpha: 0.55))
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: width * 0.12, y: height * 0.20))
    ctx.addLine(to: CGPoint(x: width * 0.34, y: height * 0.20))
    ctx.strokePath()
    ctx.restoreGState()

    // Small pill "macOS 14+"
    drawPill(
        ctx: ctx,
        text: "macOS 14+",
        x: width * 0.12,
        y: height * 0.14,
        background: CGColor(red: 1, green: 1, blue: 1, alpha: 0.07),
        stroke: CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
        textColor: CGColor(red: 1, green: 1, blue: 1, alpha: 0.78)
    )

    // Mini "record dot" in the corner for brand recognition
    ctx.saveGState()
    ctx.setFillColor(accent)
    ctx.fillEllipse(in: CGRect(x: width - 70, y: height - 70, width: 18, height: 18))
    ctx.setFillColor(CGColor(red: 0xE6 / 255.0, green: 0x39 / 255.0, blue: 0x46 / 255.0, alpha: 0.18))
    ctx.fillEllipse(in: CGRect(x: width - 88, y: height - 88, width: 54, height: 54))
    ctx.restoreGState()

    return ctx.makeImage()
}

// MARK: - Text helpers

enum TextAlignment {
    case left
    case center
}

func drawText(
    ctx: CGContext,
    text: String,
    x: CGFloat,
    y: CGFloat,
    fontSize: CGFloat,
    fontWeight: NSFont.Weight,
    color: CGColor,
    tracking: CGFloat,
    alignment: TextAlignment
) {
    let font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color) ?? NSColor.white,
        .kern: tracking,
    ]
    let attrString = NSAttributedString(string: text, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attrString)
    let bounds = CTLineGetBoundsWithOptions(line, [])

    ctx.saveGState()
    let drawX: CGFloat
    switch alignment {
    case .left:
        drawX = x
    case .center:
        drawX = x - bounds.width / 2 - bounds.origin.x
    }
    ctx.textPosition = CGPoint(x: drawX, y: y - bounds.height / 2 - bounds.origin.y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func drawPill(
    ctx: CGContext,
    text: String,
    x: CGFloat,
    y: CGFloat,
    background: CGColor,
    stroke: CGColor,
    textColor: CGColor
) {
    let font = NSFont.systemFont(ofSize: 20, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: textColor) ?? NSColor.white,
    ]
    let attrString = NSAttributedString(string: text, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attrString)
    let bounds = CTLineGetBoundsWithOptions(line, [])

    let paddingX: CGFloat = 18
    let paddingY: CGFloat = 10
    let pillW = bounds.width + paddingX * 2
    let pillH = bounds.height + paddingY * 2
    let radius = pillH / 2
    let rect = CGRect(x: x, y: y - pillH / 2, width: pillW, height: pillH)

    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setFillColor(background)
    ctx.addPath(path)
    ctx.fillPath()

    ctx.setStrokeColor(stroke)
    ctx.setLineWidth(1)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.textPosition = CGPoint(x: x + paddingX, y: y - bounds.height / 2 - bounds.origin.y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - Export

func savePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        print("❌ Failed to create image destination for \(url.lastPathComponent)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    if CGImageDestinationFinalize(dest) {
        print("✅ Exported: \(url.lastPathComponent) (\(image.width)×\(image.height))")
    } else {
        print("❌ Failed to finalize \(url.lastPathComponent)")
    }
}

// MARK: - Main

func main() {
    let scriptDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
    let projectRoot = scriptDir.deletingLastPathComponent()

    let docsDir = projectRoot.appendingPathComponent("docs")
    let outputURL = docsDir.appendingPathComponent("og-image.png")

    let fm = FileManager.default
    try? fm.createDirectory(at: docsDir, withIntermediateDirectories: true)

    print("🎨 Generating Kōji OG image...")
    if let image = renderOGImage() {
        savePNG(image, to: outputURL)
        print("   Output: \(outputURL.path)")
    }
}

main()
