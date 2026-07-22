#!/usr/bin/env swift
//
// generate_dmg_background.swift
// Generates the DMG installer background image for Kōji.
//
// Usage: swift scripts/generate_dmg_background.swift
//
// Output:
//   resources/dmg-background.png    (660×400 @1x)
//   resources/dmg-background@2x.png (1320×800 @2x)
//

import Foundation
import AppKit

// MARK: - Configuration

/// Logical dimensions (points) — the DMG window size
let logicalWidth: CGFloat = 660
let logicalHeight: CGFloat = 400

/// Finder icon placement zones (logical points from left edge)
/// Note: Finder uses top-left origin. CG uses bottom-left.
/// Finder Y=190 → CG Y = 400 - 190 = 210
let appIconCenterX: CGFloat = 170    // .app icon center
let aliasIconCenterX: CGFloat = 490  // Applications alias center
let iconCenterY: CGFloat = 210      // CG Y (= Finder Y 190 from top)
let iconZoneSize: CGFloat = 128     // visual reference size (matches DMG icon size)

// Colors
let bgColorTop    = CGColor(red: 0x16/255.0, green: 0x1B/255.0, blue: 0x22/255.0, alpha: 1.0) // #161B22
let bgColorBottom = CGColor(red: 0x0D/255.0, green: 0x11/255.0, blue: 0x17/255.0, alpha: 1.0) // #0D1117
let accentRed     = CGColor(red: 0xE6/255.0, green: 0x39/255.0, blue: 0x46/255.0, alpha: 1.0) // #E63946
let accentRedGlow = CGColor(red: 0xE6/255.0, green: 0x39/255.0, blue: 0x46/255.0, alpha: 0.25)
let titleWhite    = CGColor(red: 0xF0/255.0, green: 0xF6/255.0, blue: 0xFC/255.0, alpha: 1.0) // #F0F6FC
let subtitleGray  = CGColor(red: 0x8B/255.0, green: 0x94/255.0, blue: 0x9E/255.0, alpha: 1.0) // #8B949E
let mutedGray     = CGColor(red: 0x48/255.0, green: 0x4F/255.0, blue: 0x58/255.0, alpha: 1.0) // #484F58
let dotColor      = CGColor(red: 0x21/255.0, green: 0x26/255.0, blue: 0x2D/255.0, alpha: 1.0) // #21262D

// MARK: - Drawing

func renderDMGBackground(scale: CGFloat) -> CGImage? {
    let w = logicalWidth * scale
    let h = logicalHeight * scale

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: Int(w),
        height: Int(h),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        print("❌ Failed to create CGContext")
        return nil
    }

    // Scale everything to match pixel density
    ctx.scaleBy(x: scale, y: scale)

    // Full rect for reference
    _ = CGRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight)

    // --- 1. Background gradient ---
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [bgColorBottom, bgColorTop] as CFArray,  // bottom → top in CG coords
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: logicalWidth / 2, y: 0),
        end: CGPoint(x: logicalWidth / 2, y: logicalHeight),
        options: []
    )

    // --- 2. Subtle dot grid pattern for texture ---
    let dotSpacing: CGFloat = 20
    let dotRadius: CGFloat = 0.6
    ctx.setFillColor(dotColor)
    var dy: CGFloat = 10
    while dy < logicalHeight {
        var dx: CGFloat = 10
        while dx < logicalWidth {
            ctx.fillEllipse(in: CGRect(
                x: dx - dotRadius,
                y: dy - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
            dx += dotSpacing
        }
        dy += dotSpacing
    }

    // --- 3. Title "KŌJI" ---
    // CG coordinate system: origin at bottom-left, y increases upward
    let titleY = logicalHeight - 90  // near top
    drawText(
        ctx: ctx,
        text: "K Ō J I",
        x: logicalWidth / 2,
        y: titleY,
        fontSize: 38,
        fontWeight: .bold,
        color: titleWhite,
        tracking: 12.0
    )

    // --- 4. Subtitle ---
    let subtitleY = titleY - 32
    drawText(
        ctx: ctx,
        text: "Screen & Audio Recorder",
        x: logicalWidth / 2,
        y: subtitleY,
        fontSize: 14,
        fontWeight: .medium,
        color: subtitleGray,
        tracking: 2.0
    )

    // --- 5. Curved drag arrow from app icon zone to Applications zone ---
    drawDragArrow(ctx: ctx, scale: scale)

    // --- 6. "drag" label above the arrow ---
    let arrowMidX = (appIconCenterX + aliasIconCenterX) / 2
    let arrowLabelY = iconCenterY + 14
    drawText(
        ctx: ctx,
        text: "drag here",
        x: arrowMidX,
        y: arrowLabelY,
        fontSize: 11,
        fontWeight: .medium,
        color: CGColor(red: 0xE6/255.0, green: 0x39/255.0, blue: 0x46/255.0, alpha: 0.6),
        tracking: 1.0
    )

    // --- 7. Subtle circle outlines for icon placement zones ---
    drawIconZone(ctx: ctx, centerX: appIconCenterX, centerY: iconCenterY, label: nil)
    drawIconZone(ctx: ctx, centerX: aliasIconCenterX, centerY: iconCenterY, label: nil)

    // --- 8. Version info at bottom ---
    let versionY: CGFloat = 35
    drawText(
        ctx: ctx,
        text: "v1.0.0 · macOS 14+",
        x: logicalWidth / 2,
        y: versionY,
        fontSize: 11,
        fontWeight: .regular,
        color: mutedGray,
        tracking: 1.5
    )

    // --- 9. Subtle bottom accent line ---
    let lineWidth: CGFloat = 80
    let lineY: CGFloat = 18
    ctx.setStrokeColor(CGColor(red: 0xE6/255.0, green: 0x39/255.0, blue: 0x46/255.0, alpha: 0.3))
    ctx.setLineWidth(1.5)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: logicalWidth / 2 - lineWidth / 2, y: lineY))
    ctx.addLine(to: CGPoint(x: logicalWidth / 2 + lineWidth / 2, y: lineY))
    ctx.strokePath()

    return ctx.makeImage()
}

// MARK: - Arrow Drawing

func drawDragArrow(ctx: CGContext, scale: CGFloat) {
    let startX = appIconCenterX + 52
    let endX = aliasIconCenterX - 52
    let y = iconCenterY

    // Arrow body: gentle curve
    let controlOffset: CGFloat = 22

    // Glow layer
    ctx.saveGState()
    ctx.setStrokeColor(accentRedGlow)
    ctx.setLineWidth(6.0)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: startX, y: y))
    ctx.addQuadCurve(
        to: CGPoint(x: endX - 8, y: y),
        control: CGPoint(x: (startX + endX) / 2, y: y + controlOffset)
    )
    ctx.strokePath()
    ctx.restoreGState()

    // Main arrow line
    ctx.saveGState()
    ctx.setStrokeColor(accentRed)
    ctx.setLineWidth(2.0)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: startX, y: y))
    ctx.addQuadCurve(
        to: CGPoint(x: endX - 8, y: y),
        control: CGPoint(x: (startX + endX) / 2, y: y + controlOffset)
    )
    ctx.strokePath()
    ctx.restoreGState()

    // Arrow head (small chevron)
    let arrowSize: CGFloat = 10
    let tipX = endX - 6
    let tipY = y

    ctx.saveGState()
    ctx.setStrokeColor(accentRed)
    ctx.setLineWidth(2.0)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    ctx.move(to: CGPoint(x: tipX - arrowSize, y: tipY + arrowSize * 0.6))
    ctx.addLine(to: CGPoint(x: tipX, y: tipY))
    ctx.addLine(to: CGPoint(x: tipX - arrowSize, y: tipY - arrowSize * 0.6))
    ctx.strokePath()
    ctx.restoreGState()

    // Small dots along the path for style
    let dotCount = 3
    for i in 0..<dotCount {
        let t = CGFloat(i + 1) / CGFloat(dotCount + 1)
        // Quadratic bezier interpolation
        let px = (1 - t) * (1 - t) * startX + 2 * (1 - t) * t * ((startX + endX) / 2) + t * t * (endX - 8)
        let py = (1 - t) * (1 - t) * y + 2 * (1 - t) * t * (y + controlOffset) + t * t * y
        let dotR: CGFloat = 1.5
        ctx.setFillColor(CGColor(red: 0xE6/255.0, green: 0x39/255.0, blue: 0x46/255.0, alpha: 0.4))
        ctx.fillEllipse(in: CGRect(x: px - dotR, y: py - dotR, width: dotR * 2, height: dotR * 2))
    }
}

// MARK: - Icon Zone

func drawIconZone(ctx: CGContext, centerX: CGFloat, centerY: CGFloat, label: String?) {
    let radius: CGFloat = 44

    // Dashed circle outline
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 0x30/255.0, green: 0x36/255.0, blue: 0x3D/255.0, alpha: 0.5))
    ctx.setLineWidth(1.0)
    ctx.setLineDash(phase: 0, lengths: [4, 4])
    ctx.addEllipse(in: CGRect(
        x: centerX - radius,
        y: centerY - radius,
        width: radius * 2,
        height: radius * 2
    ))
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Text Drawing

func drawText(
    ctx: CGContext,
    text: String,
    x: CGFloat,
    y: CGFloat,
    fontSize: CGFloat,
    fontWeight: NSFont.Weight,
    color: CGColor,
    tracking: CGFloat
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
    ctx.textPosition = CGPoint(
        x: x - bounds.width / 2 - bounds.origin.x,
        y: y - bounds.height / 2 - bounds.origin.y
    )
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
    let outputDir = projectRoot.appendingPathComponent("resources")

    let fm = FileManager.default
    try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

    print("🎨 Generating Kōji DMG background...")

    // @1x (660×400)
    if let image1x = renderDMGBackground(scale: 1.0) {
        let url = outputDir.appendingPathComponent("dmg-background.png")
        savePNG(image1x, to: url)
    }

    // @2x (1320×800)
    if let image2x = renderDMGBackground(scale: 2.0) {
        let url = outputDir.appendingPathComponent("dmg-background@2x.png")
        savePNG(image2x, to: url)
    }

    print("\n🎉 DMG background generation complete!")
    print("   Output: \(outputDir.path)")
}

main()
