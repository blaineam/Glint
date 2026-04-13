#!/usr/bin/env swift
//
// generate-web-assets.swift
// Generates favicon, apple-touch-icon, and Open Graph poster for the Glint site.
//
// Usage:
//   swift Scripts/generate-web-assets.swift docs
//
// Outputs:
//   docs/favicon.png          — 32×32 favicon
//   docs/favicon-96.png       — 96×96 favicon (high-DPI)
//   docs/apple-touch-icon.png — 180×180 iOS homescreen icon
//   docs/og-poster.png        — 1200×630 Open Graph image
//

import AppKit
import CoreGraphics
import Foundation

// ---------------------------------------------------------------------------
// MARK: - Helpers
// ---------------------------------------------------------------------------

func renderImage(size: NSSize, _ draw: (CGContext) -> Void) -> NSImage {
    let img = NSImage(size: size)
    img.lockFocus()
    if let ctx = NSGraphicsContext.current?.cgContext {
        draw(ctx)
    }
    img.unlockFocus()
    return img
}

func pngData(from image: NSImage) -> Data {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fputs("ERROR: Failed to create PNG data\n", stderr)
        exit(1)
    }
    return png
}

// ---------------------------------------------------------------------------
// MARK: - Brand Colors
// ---------------------------------------------------------------------------

let glintGold    = CGColor(red: 1.00, green: 0.76, blue: 0.22, alpha: 1.0)
let glintAmber   = CGColor(red: 1.00, green: 0.60, blue: 0.10, alpha: 1.0)
let glintDeep    = CGColor(red: 0.85, green: 0.45, blue: 0.05, alpha: 1.0)

// ---------------------------------------------------------------------------
// MARK: - Logo Drawing
// ---------------------------------------------------------------------------

func drawGlintLogo(in cg: CGContext, center: CGPoint, size: CGFloat) {
    let s = size
    cg.saveGState()
    cg.translateBy(x: center.x, y: center.y)

    // Monitor body
    let monW = s * 0.72
    let monH = s * 0.48
    let monR = s * 0.06
    let monRect = CGRect(x: -monW / 2, y: -monH / 2 + s * 0.08, width: monW, height: monH)
    let monPath = CGPath(roundedRect: monRect, cornerWidth: monR, cornerHeight: monR, transform: nil)

    cg.saveGState()
    cg.addPath(monPath)
    cg.clip()
    let monColors = [
        CGColor(red: 0.15, green: 0.13, blue: 0.22, alpha: 1.0),
        CGColor(red: 0.08, green: 0.07, blue: 0.12, alpha: 1.0),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: monColors, locations: [0.0, 1.0]) {
        cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: monRect.maxY), end: CGPoint(x: 0, y: monRect.minY), options: [])
    }
    cg.restoreGState()

    cg.setStrokeColor(CGColor(red: 0.3, green: 0.28, blue: 0.35, alpha: 0.8))
    cg.setLineWidth(s * 0.015)
    cg.addPath(monPath)
    cg.strokePath()

    // Stand
    let standW = s * 0.12
    let standH = s * 0.10
    let standTop = monRect.minY
    let standPath = CGMutablePath()
    standPath.move(to: CGPoint(x: -standW / 2, y: standTop))
    standPath.addLine(to: CGPoint(x: standW / 2, y: standTop))
    standPath.addLine(to: CGPoint(x: standW * 0.7, y: standTop - standH))
    standPath.addLine(to: CGPoint(x: -standW * 0.7, y: standTop - standH))
    standPath.closeSubpath()
    cg.setFillColor(CGColor(red: 0.22, green: 0.20, blue: 0.28, alpha: 1.0))
    cg.addPath(standPath)
    cg.fillPath()

    let baseW = s * 0.28
    let baseH = s * 0.025
    let baseY = standTop - standH
    let baseRect = CGRect(x: -baseW / 2, y: baseY - baseH, width: baseW, height: baseH)
    let basePath = CGPath(roundedRect: baseRect, cornerWidth: baseH / 2, cornerHeight: baseH / 2, transform: nil)
    cg.setFillColor(CGColor(red: 0.22, green: 0.20, blue: 0.28, alpha: 1.0))
    cg.addPath(basePath)
    cg.fillPath()

    // Sun
    let sunCenter = CGPoint(x: s * 0.02, y: s * 0.12)
    let sunR = s * 0.10

    cg.saveGState()
    let glowColors = [
        CGColor(red: 1.0, green: 0.85, blue: 0.40, alpha: 0.6),
        CGColor(red: 1.0, green: 0.70, blue: 0.20, alpha: 0.0),
    ] as CFArray
    if let glowGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0.0, 1.0]) {
        cg.drawRadialGradient(glowGrad, startCenter: sunCenter, startRadius: 0, endCenter: sunCenter, endRadius: sunR * 2.5, options: [])
    }
    cg.restoreGState()

    cg.saveGState()
    let sunCircle = CGRect(x: sunCenter.x - sunR, y: sunCenter.y - sunR, width: sunR * 2, height: sunR * 2)
    cg.addEllipse(in: sunCircle)
    cg.clip()
    let sunColors = [glintGold, glintAmber] as CFArray
    if let sunGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sunColors, locations: [0.0, 1.0]) {
        cg.drawLinearGradient(sunGrad, start: CGPoint(x: sunCenter.x, y: sunCenter.y + sunR), end: CGPoint(x: sunCenter.x, y: sunCenter.y - sunR), options: [])
    }
    cg.restoreGState()

    // Rays
    let rayCount = 8
    let rayInner = sunR * 1.35
    let rayOuter = sunR * 1.85
    cg.setStrokeColor(glintGold)
    cg.setLineWidth(s * 0.018)
    cg.setLineCap(.round)
    for i in 0..<rayCount {
        let angle = CGFloat(i) * .pi * 2 / CGFloat(rayCount)
        let inner = CGPoint(x: sunCenter.x + cos(angle) * rayInner, y: sunCenter.y + sin(angle) * rayInner)
        let outer = CGPoint(x: sunCenter.x + cos(angle) * rayOuter, y: sunCenter.y + sin(angle) * rayOuter)
        cg.move(to: inner)
        cg.addLine(to: outer)
        cg.strokePath()
    }

    // Sparkle
    let sparkCenter = CGPoint(x: sunCenter.x + sunR * 1.4, y: sunCenter.y + sunR * 1.2)
    drawSparkle(in: cg, center: sparkCenter, size: s * 0.06, color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))

    cg.restoreGState()
}

func drawSparkle(in cg: CGContext, center: CGPoint, size: CGFloat, color: CGColor) {
    let path = CGMutablePath()
    let arm = size
    let narrow = size * 0.2
    path.move(to: CGPoint(x: center.x, y: center.y + arm))
    path.addCurve(to: CGPoint(x: center.x, y: center.y - arm),
                  control1: CGPoint(x: center.x + narrow, y: center.y),
                  control2: CGPoint(x: center.x + narrow, y: center.y))
    path.addCurve(to: CGPoint(x: center.x, y: center.y + arm),
                  control1: CGPoint(x: center.x - narrow, y: center.y),
                  control2: CGPoint(x: center.x - narrow, y: center.y))
    path.closeSubpath()
    path.move(to: CGPoint(x: center.x + arm, y: center.y))
    path.addCurve(to: CGPoint(x: center.x - arm, y: center.y),
                  control1: CGPoint(x: center.x, y: center.y + narrow),
                  control2: CGPoint(x: center.x, y: center.y + narrow))
    path.addCurve(to: CGPoint(x: center.x + arm, y: center.y),
                  control1: CGPoint(x: center.x, y: center.y - narrow),
                  control2: CGPoint(x: center.x, y: center.y - narrow))
    path.closeSubpath()
    cg.setFillColor(color)
    cg.addPath(path)
    cg.fillPath()
}

// ---------------------------------------------------------------------------
// MARK: - Icon Generator (app icon style)
// ---------------------------------------------------------------------------

func generateIcon(size: CGFloat) -> NSImage {
    return renderImage(size: NSSize(width: size, height: size)) { cg in
        let inset = size * 0.1
        let iconRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let cornerRadius = (size - inset * 2) * 0.22
        let iconPath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        cg.saveGState()
        cg.addPath(iconPath)
        cg.clip()
        let bgColors = [
            CGColor(red: 0.12, green: 0.10, blue: 0.20, alpha: 1.0),
            CGColor(red: 0.06, green: 0.05, blue: 0.10, alpha: 1.0),
        ] as CFArray
        if let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0.0, 1.0]) {
            cg.drawLinearGradient(bgGrad, start: CGPoint(x: size / 2, y: size - inset), end: CGPoint(x: size / 2, y: inset), options: [])
        }
        let logoSize = (size - inset * 2) * 0.85
        drawGlintLogo(in: cg, center: CGPoint(x: size / 2, y: size / 2), size: logoSize)
        cg.restoreGState()

        cg.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.5, alpha: 0.15))
        cg.setLineWidth(size * 0.005)
        cg.addPath(iconPath)
        cg.strokePath()
    }
}

// ---------------------------------------------------------------------------
// MARK: - OG Poster (1200×630)
// ---------------------------------------------------------------------------

func generateOGPoster() -> NSImage {
    let w: CGFloat = 1200
    let h: CGFloat = 630

    return renderImage(size: NSSize(width: w, height: h)) { cg in
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Background gradient
        let bgColors = [
            CGColor(red: 0.06, green: 0.04, blue: 0.10, alpha: 1.0),
            CGColor(red: 0.10, green: 0.07, blue: 0.16, alpha: 1.0),
            CGColor(red: 0.08, green: 0.06, blue: 0.12, alpha: 1.0),
        ] as CFArray
        if let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.5, 1.0]) {
            cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        }

        // Warm ambient glow (left-center, behind icon)
        let glowColors = [
            CGColor(red: 1.0, green: 0.70, blue: 0.20, alpha: 0.10),
            CGColor(red: 1.0, green: 0.70, blue: 0.20, alpha: 0.0),
        ] as CFArray
        if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
            cg.drawRadialGradient(glowGrad, startCenter: CGPoint(x: w * 0.35, y: h * 0.5), startRadius: 0, endCenter: CGPoint(x: w * 0.35, y: h * 0.5), endRadius: 350, options: [])
        }

        // Subtle sparkle dots
        let sparkles: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.08, 0.15, 2.0, 0.25), (0.92, 0.12, 1.8, 0.20), (0.15, 0.88, 2.2, 0.30),
            (0.88, 0.85, 1.5, 0.15), (0.50, 0.08, 1.6, 0.20), (0.75, 0.92, 1.8, 0.22),
            (0.05, 0.50, 1.4, 0.18), (0.95, 0.50, 1.6, 0.20),
        ]
        for (sx, sy, radius, alpha) in sparkles {
            cg.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.6, alpha: alpha))
            cg.fillEllipse(in: CGRect(x: sx * w - radius, y: sy * h - radius, width: radius * 2, height: radius * 2))
        }

        // --- Logo icon (left side) ---
        let logoSize: CGFloat = 160
        let logoX = w * 0.22
        let logoY = h * 0.52

        // Icon background (rounded rect)
        let iconInset = logoSize * 0.1
        let iconRect = CGRect(x: logoX - logoSize / 2 + iconInset, y: logoY - logoSize / 2 + iconInset,
                              width: logoSize - iconInset * 2, height: logoSize - iconInset * 2)
        let iconCorner = (logoSize - iconInset * 2) * 0.22
        let iconPath = CGPath(roundedRect: iconRect, cornerWidth: iconCorner, cornerHeight: iconCorner, transform: nil)

        cg.saveGState()
        cg.addPath(iconPath)
        cg.clip()
        let iconBgColors = [
            CGColor(red: 0.12, green: 0.10, blue: 0.20, alpha: 1.0),
            CGColor(red: 0.06, green: 0.05, blue: 0.10, alpha: 1.0),
        ] as CFArray
        if let iconGrad = CGGradient(colorsSpace: colorSpace, colors: iconBgColors, locations: [0.0, 1.0]) {
            cg.drawLinearGradient(iconGrad, start: CGPoint(x: logoX, y: logoY + logoSize / 2), end: CGPoint(x: logoX, y: logoY - logoSize / 2), options: [])
        }
        drawGlintLogo(in: cg, center: CGPoint(x: logoX, y: logoY), size: (logoSize - iconInset * 2) * 0.85)
        cg.restoreGState()

        // Icon border glow
        cg.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.5, alpha: 0.2))
        cg.setLineWidth(1.5)
        cg.addPath(iconPath)
        cg.strokePath()

        // --- Text (right side) ---
        let textX = w * 0.42
        let textMaxW = w * 0.52

        // Title: "Glint"
        let titleFont = NSFont.systemFont(ofSize: 72, weight: .heavy)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .left

        // Draw "Glint" with gold gradient effect (using solid gold for simplicity in CG)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor(red: 1.0, green: 0.76, blue: 0.22, alpha: 1.0),
            .paragraphStyle: titleStyle,
        ]
        let titleStr = "Glint"
        // CoreGraphics flips text, so we need to use NSString drawing
        let titleRect = NSRect(x: textX, y: h * 0.52, width: textMaxW, height: 90)

        // Save graphics state and flip for text drawing
        let nsCtx = NSGraphicsContext(cgContext: cg, flipped: false)
        NSGraphicsContext.current = nsCtx
        titleStr.draw(in: titleRect, withAttributes: titleAttrs)

        // Tagline
        let tagFont = NSFont.systemFont(ofSize: 24, weight: .medium)
        let tagAttrs: [NSAttributedString.Key: Any] = [
            .font: tagFont,
            .foregroundColor: NSColor(white: 1.0, alpha: 0.65),
            .paragraphStyle: titleStyle,
        ]
        let tagStr = "Control all your displays'\nbrightness and volume."
        let tagRect = NSRect(x: textX, y: h * 0.30, width: textMaxW, height: 80)
        tagStr.draw(in: tagRect, withAttributes: tagAttrs)

        // Subtitle
        let subFont = NSFont.systemFont(ofSize: 16, weight: .regular)
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: subFont,
            .foregroundColor: NSColor(white: 1.0, alpha: 0.35),
            .paragraphStyle: titleStyle,
        ]
        let subStr = "Free · Open Source · macOS"
        let subRect = NSRect(x: textX, y: h * 0.18, width: textMaxW, height: 30)
        subStr.draw(in: subRect, withAttributes: subAttrs)

        // Bottom subtle line accent
        cg.setStrokeColor(CGColor(red: 1.0, green: 0.76, blue: 0.22, alpha: 0.15))
        cg.setLineWidth(2)
        cg.move(to: CGPoint(x: 40, y: 30))
        cg.addLine(to: CGPoint(x: w - 40, y: 30))
        cg.strokePath()
    }
}

// ---------------------------------------------------------------------------
// MARK: - Main
// ---------------------------------------------------------------------------

let outputDir: String
if CommandLine.arguments.count >= 2 {
    outputDir = CommandLine.arguments[1]
} else {
    outputDir = "docs"
}

try! FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// Favicon 32×32
let fav32 = generateIcon(size: 32)
try! pngData(from: fav32).write(to: URL(fileURLWithPath: "\(outputDir)/favicon.png"))
fputs("Created: \(outputDir)/favicon.png\n", stderr)

// Favicon 96×96 (high-DPI / Google)
let fav96 = generateIcon(size: 96)
try! pngData(from: fav96).write(to: URL(fileURLWithPath: "\(outputDir)/favicon-96.png"))
fputs("Created: \(outputDir)/favicon-96.png\n", stderr)

// Apple Touch Icon 180×180
let touch = generateIcon(size: 180)
try! pngData(from: touch).write(to: URL(fileURLWithPath: "\(outputDir)/apple-touch-icon.png"))
fputs("Created: \(outputDir)/apple-touch-icon.png\n", stderr)

// OG Poster 1200×630
let poster = generateOGPoster()
try! pngData(from: poster).write(to: URL(fileURLWithPath: "\(outputDir)/og-poster.png"))
fputs("Created: \(outputDir)/og-poster.png\n", stderr)

fputs("Done.\n", stderr)
