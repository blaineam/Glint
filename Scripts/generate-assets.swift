#!/usr/bin/env swift
//
// generate-assets.swift
// Generates the Glint app icon (.icns) and DMG background image.
//
// Usage:
//   swift generate-assets.swift <output-dir>
//
// Outputs:
//   <output-dir>/AppIcon.icns          — app icon
//   <output-dir>/dmg-background.jpg    — styled DMG installer background (660×400)
//

import AppKit
import CoreGraphics
import Foundation

// ---------------------------------------------------------------------------
// MARK: - Helpers
// ---------------------------------------------------------------------------

func renderImage(size: NSSize, _ draw: (NSGraphicsContext) -> Void) -> NSImage {
    // Use NSBitmapImageRep to guarantee exact pixel dimensions (no Retina 2x scaling)
    let w = Int(size.width)
    let h = Int(size.height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size  // logical size = pixel size (1x)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()

    let img = NSImage(size: size)
    img.addRepresentation(rep)
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

func jpegData(from image: NSImage, quality: Double = 0.6) -> Data {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let jpeg = rep.representation(using: .jpeg,
                                        properties: [.compressionFactor: quality]) else {
        fputs("ERROR: Failed to create JPEG data\n", stderr)
        exit(1)
    }
    return jpeg
}

// ---------------------------------------------------------------------------
// MARK: - Glint Brand Colors
// ---------------------------------------------------------------------------

// Warm amber/gold — evokes a glint of light
let glintGold    = CGColor(red: 1.00, green: 0.76, blue: 0.22, alpha: 1.0)  // #FFC238
let glintAmber   = CGColor(red: 1.00, green: 0.60, blue: 0.10, alpha: 1.0)  // #FF991A
let glintDeep    = CGColor(red: 0.85, green: 0.45, blue: 0.05, alpha: 1.0)  // #D97308
let glintBgDark  = CGColor(red: 0.08, green: 0.07, blue: 0.12, alpha: 1.0)  // #141220
let glintBgMid   = CGColor(red: 0.12, green: 0.10, blue: 0.18, alpha: 1.0)  // #1F1A2E

// ---------------------------------------------------------------------------
// MARK: - Glint Logo Drawing (sun/display glint icon)
// ---------------------------------------------------------------------------

/// Draws the Glint logo: a stylized display with a brightness glint.
/// Programmatic vector art — no external assets needed.
func drawGlintLogo(in cg: CGContext, center: CGPoint, size: CGFloat) {
    let s = size
    cg.saveGState()
    cg.translateBy(x: center.x, y: center.y)

    // --- Monitor body (rounded rect) ---
    let monW = s * 0.72
    let monH = s * 0.48
    let monR = s * 0.06
    let monRect = CGRect(x: -monW / 2, y: -monH / 2 + s * 0.08,
                         width: monW, height: monH)
    let monPath = CGPath(roundedRect: monRect, cornerWidth: monR, cornerHeight: monR, transform: nil)

    // Monitor fill — dark gradient
    cg.saveGState()
    cg.addPath(monPath)
    cg.clip()
    let monColors = [
        CGColor(red: 0.15, green: 0.13, blue: 0.22, alpha: 1.0),
        CGColor(red: 0.08, green: 0.07, blue: 0.12, alpha: 1.0),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: monColors, locations: [0.0, 1.0]) {
        cg.drawLinearGradient(grad,
                              start: CGPoint(x: 0, y: monRect.maxY),
                              end: CGPoint(x: 0, y: monRect.minY),
                              options: [])
    }
    cg.restoreGState()

    // Monitor border
    cg.setStrokeColor(CGColor(red: 0.3, green: 0.28, blue: 0.35, alpha: 0.8))
    cg.setLineWidth(s * 0.015)
    cg.addPath(monPath)
    cg.strokePath()

    // --- Monitor stand ---
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

    // Stand base
    let baseW = s * 0.28
    let baseH = s * 0.025
    let baseY = standTop - standH
    let baseRect = CGRect(x: -baseW / 2, y: baseY - baseH, width: baseW, height: baseH)
    let basePath = CGPath(roundedRect: baseRect, cornerWidth: baseH / 2, cornerHeight: baseH / 2, transform: nil)
    cg.setFillColor(CGColor(red: 0.22, green: 0.20, blue: 0.28, alpha: 1.0))
    cg.addPath(basePath)
    cg.fillPath()

    // --- Sun/glint symbol on screen ---
    let sunCenter = CGPoint(x: s * 0.02, y: s * 0.12)
    let sunR = s * 0.10

    // Sun glow (radial gradient)
    cg.saveGState()
    let glowColors = [
        CGColor(red: 1.0, green: 0.85, blue: 0.40, alpha: 0.6),
        CGColor(red: 1.0, green: 0.70, blue: 0.20, alpha: 0.0),
    ] as CFArray
    if let glowGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: glowColors, locations: [0.0, 1.0]) {
        cg.drawRadialGradient(glowGrad,
                              startCenter: sunCenter, startRadius: 0,
                              endCenter: sunCenter, endRadius: sunR * 2.5,
                              options: [])
    }
    cg.restoreGState()

    // Sun circle
    cg.saveGState()
    let sunCircle = CGRect(x: sunCenter.x - sunR, y: sunCenter.y - sunR,
                           width: sunR * 2, height: sunR * 2)
    cg.addEllipse(in: sunCircle)
    cg.clip()
    let sunColors = [glintGold, glintAmber] as CFArray
    if let sunGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: sunColors, locations: [0.0, 1.0]) {
        cg.drawLinearGradient(sunGrad,
                              start: CGPoint(x: sunCenter.x, y: sunCenter.y + sunR),
                              end: CGPoint(x: sunCenter.x, y: sunCenter.y - sunR),
                              options: [])
    }
    cg.restoreGState()

    // Sun rays
    let rayCount = 8
    let rayInner = sunR * 1.35
    let rayOuter = sunR * 1.85
    cg.setStrokeColor(glintGold)
    cg.setLineWidth(s * 0.018)
    cg.setLineCap(.round)
    for i in 0..<rayCount {
        let angle = CGFloat(i) * .pi * 2 / CGFloat(rayCount)
        let inner = CGPoint(x: sunCenter.x + cos(angle) * rayInner,
                            y: sunCenter.y + sin(angle) * rayInner)
        let outer = CGPoint(x: sunCenter.x + cos(angle) * rayOuter,
                            y: sunCenter.y + sin(angle) * rayOuter)
        cg.move(to: inner)
        cg.addLine(to: outer)
        cg.strokePath()
    }

    // --- Glint sparkle (top-right of sun) ---
    let sparkCenter = CGPoint(x: sunCenter.x + sunR * 1.4, y: sunCenter.y + sunR * 1.2)
    drawSparkle(in: cg, center: sparkCenter, size: s * 0.06, color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))

    cg.restoreGState()
}

/// Draws a 4-pointed sparkle/glint star.
func drawSparkle(in cg: CGContext, center: CGPoint, size: CGFloat, color: CGColor) {
    let path = CGMutablePath()
    let arm = size
    let narrow = size * 0.2

    // Vertical axis
    path.move(to: CGPoint(x: center.x, y: center.y + arm))
    path.addCurve(to: CGPoint(x: center.x, y: center.y - arm),
                  control1: CGPoint(x: center.x + narrow, y: center.y),
                  control2: CGPoint(x: center.x + narrow, y: center.y))
    path.addCurve(to: CGPoint(x: center.x, y: center.y + arm),
                  control1: CGPoint(x: center.x - narrow, y: center.y),
                  control2: CGPoint(x: center.x - narrow, y: center.y))
    path.closeSubpath()

    // Horizontal axis
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
// MARK: - App Icon Generation
// ---------------------------------------------------------------------------

func generateAppIcon(size: CGFloat) -> NSImage {
    return renderImage(size: NSSize(width: size, height: size)) { ctx in
        let cg = ctx.cgContext

        // macOS icon shape: rounded rect (continuous corners)
        let inset = size * 0.1
        let iconRect = CGRect(x: inset, y: inset,
                              width: size - inset * 2, height: size - inset * 2)
        let cornerRadius = (size - inset * 2) * 0.22

        let iconPath = CGPath(roundedRect: iconRect,
                              cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                              transform: nil)

        // Background gradient
        cg.saveGState()
        cg.addPath(iconPath)
        cg.clip()

        let bgColors = [
            CGColor(red: 0.12, green: 0.10, blue: 0.20, alpha: 1.0),
            CGColor(red: 0.06, green: 0.05, blue: 0.10, alpha: 1.0),
        ] as CFArray
        if let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: bgColors, locations: [0.0, 1.0]) {
            cg.drawLinearGradient(bgGrad,
                                  start: CGPoint(x: size / 2, y: size - inset),
                                  end: CGPoint(x: size / 2, y: inset),
                                  options: [])
        }

        // Draw the logo centered
        let logoSize = (size - inset * 2) * 0.85
        drawGlintLogo(in: cg, center: CGPoint(x: size / 2, y: size / 2), size: logoSize)
        cg.restoreGState()

        // Subtle border
        cg.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.5, alpha: 0.15))
        cg.setLineWidth(size * 0.005)
        cg.addPath(iconPath)
        cg.strokePath()
    }
}

func createIconset(outputDir: String) -> String {
    let iconsetPath = "\(outputDir)/AppIcon.iconset"
    try! FileManager.default.createDirectory(atPath: iconsetPath,
                                              withIntermediateDirectories: true)

    let sizes: [(String, CGFloat)] = [
        ("icon_16x16.png",      16),
        ("icon_16x16@2x.png",   32),
        ("icon_32x32.png",      32),
        ("icon_32x32@2x.png",   64),
        ("icon_128x128.png",    128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png",    256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png",    512),
        ("icon_512x512@2x.png", 1024),
    ]

    for (name, size) in sizes {
        let icon = generateAppIcon(size: size)
        let data = pngData(from: icon)
        try! data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
    }

    let icnsPath = "\(outputDir)/AppIcon.icns"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconsetPath, "-o", icnsPath]
    try! proc.run()
    proc.waitUntilExit()

    if proc.terminationStatus != 0 {
        fputs("ERROR: iconutil failed\n", stderr)
        exit(1)
    }

    try? FileManager.default.removeItem(atPath: iconsetPath)
    return icnsPath
}

// Also generate individual PNG for Assets.xcassets
func generateIconPNGs(outputDir: String) {
    let pngDir = "\(outputDir)/icon-pngs"
    try! FileManager.default.createDirectory(atPath: pngDir, withIntermediateDirectories: true)

    let sizes: [(String, CGFloat)] = [
        ("icon-1024.png", 1024),
        ("icon-512.png", 512),
        ("icon-256.png", 256),
        ("icon-128.png", 128),
        ("icon-64.png", 64),
        ("icon-32.png", 32),
        ("icon-16.png", 16),
    ]

    for (name, size) in sizes {
        let icon = generateAppIcon(size: size)
        let data = pngData(from: icon)
        try! data.write(to: URL(fileURLWithPath: "\(pngDir)/\(name)"))
    }
    fputs("Created icon PNGs in: \(pngDir)\n", stderr)
}

// ---------------------------------------------------------------------------
// MARK: - DMG Background
// ---------------------------------------------------------------------------

func generateDMGBackground(scale: CGFloat) -> NSImage {
    let w: CGFloat = 660 * scale
    let h: CGFloat = 400 * scale

    return renderImage(size: NSSize(width: w, height: h)) { ctx in
        let cg = ctx.cgContext
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // --- Background gradient (deep purple-black with amber tint) ---
        let colors = [
            CGColor(red: 0.06, green: 0.04, blue: 0.10, alpha: 1.0),
            CGColor(red: 0.10, green: 0.07, blue: 0.16, alpha: 1.0),
            CGColor(red: 0.14, green: 0.10, blue: 0.20, alpha: 1.0),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.6, 1.0]) {
            cg.drawLinearGradient(gradient,
                                  start: CGPoint(x: 0, y: h),
                                  end: CGPoint(x: 0, y: 0),
                                  options: [])
        }

        // --- Warm ambient glow (center) ---
        let glowColors = [
            CGColor(red: 1.0, green: 0.70, blue: 0.20, alpha: 0.08),
            CGColor(red: 1.0, green: 0.70, blue: 0.20, alpha: 0.0),
        ] as CFArray
        if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
            cg.drawRadialGradient(glowGrad,
                                  startCenter: CGPoint(x: w / 2, y: h * 0.55),
                                  startRadius: 0,
                                  endCenter: CGPoint(x: w / 2, y: h * 0.55),
                                  endRadius: w * 0.45,
                                  options: [])
        }

        // --- Subtle sparkle dots ---
        let sparkles: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.15, 0.85, 1.8, 0.3), (0.30, 0.90, 1.5, 0.2), (0.50, 0.88, 2.0, 0.35),
            (0.70, 0.92, 1.6, 0.25), (0.85, 0.84, 2.2, 0.3), (0.10, 0.72, 1.2, 0.15),
            (0.40, 0.76, 1.4, 0.2), (0.60, 0.80, 1.8, 0.25), (0.90, 0.75, 1.3, 0.2),
        ]
        for (sx, sy, radius, alpha) in sparkles {
            let r = radius * scale
            cg.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.6, alpha: alpha))
            cg.fillEllipse(in: CGRect(x: sx * w - r, y: sy * h - r,
                                       width: r * 2, height: r * 2))
        }

        // --- Glint logo (small, top center) ---
        let logoSize: CGFloat = 50 * scale
        drawGlintLogo(in: cg, center: CGPoint(x: w / 2, y: h * 0.87), size: logoSize)

        // --- Title ---
        let titleFontSize: CGFloat = 24 * scale
        let titleFont = NSFont.systemFont(ofSize: titleFontSize, weight: .semibold)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor(red: 1.0, green: 0.90, blue: 0.70, alpha: 0.95),
            .paragraphStyle: titleStyle
        ]
        let title = "Glint"
        let titleRect = NSRect(x: 0, y: h * 0.70, width: w, height: titleFontSize * 1.5)
        title.draw(in: titleRect, withAttributes: titleAttrs)

        // --- Subtitle ---
        let subFontSize: CGFloat = 13 * scale
        let subFont = NSFont.systemFont(ofSize: subFontSize, weight: .regular)
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: subFont,
            .foregroundColor: NSColor(white: 1.0, alpha: 0.50),
            .paragraphStyle: titleStyle
        ]
        let subtitle = "Drag to Applications to install"
        let subRect = NSRect(x: 0, y: h * 0.63, width: w, height: subFontSize * 1.5)
        subtitle.draw(in: subRect, withAttributes: subAttrs)

        // --- Arrow ---
        let arrowY = h * 0.42
        let arrowStartX = w * 0.38
        let arrowEndX = w * 0.62

        cg.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.5, alpha: 0.35))
        cg.setLineWidth(2.5 * scale)
        cg.setLineCap(.round)
        cg.move(to: CGPoint(x: arrowStartX, y: arrowY))
        cg.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
        cg.strokePath()

        let headSize: CGFloat = 10 * scale
        cg.move(to: CGPoint(x: arrowEndX - headSize, y: arrowY + headSize))
        cg.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
        cg.addLine(to: CGPoint(x: arrowEndX - headSize, y: arrowY - headSize))
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
    outputDir = "build/assets"
}

try! FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// Generate .icns
let icnsPath = createIconset(outputDir: outputDir)
fputs("Created: \(icnsPath)\n", stderr)

// Generate icon PNGs for Assets.xcassets
generateIconPNGs(outputDir: outputDir)

// Generate DMG background
let bg = generateDMGBackground(scale: 1.0)
let bgPath = "\(outputDir)/dmg-background.jpg"
let bgData = jpegData(from: bg, quality: 0.5)
try! bgData.write(to: URL(fileURLWithPath: bgPath))
fputs("Created: \(bgPath) (\(bgData.count / 1024)KB)\n", stderr)

fputs("Done.\n", stderr)
