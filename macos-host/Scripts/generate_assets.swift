import ImageIO
import Foundation
import AppKit
import CoreGraphics

// MARK: - Helper to save NSBitmapImageRep as PNG

func savePNG(_ rep: NSBitmapImageRep, to path: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AuraAssetGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: - 1. Generate AppIcon (macOS Squircle with Glowing Aura Rings & Lock Emblem)

func renderAppIcon(pixelSize: Int, pointSize: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
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
    )!

    rep.size = NSSize(width: pointSize, height: pointSize)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let s = CGFloat(pixelSize)
    let inset = s * 0.08
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225

    // Outer shadow glow
    cg.saveGState()
    let squircle = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    squircle.addClip()

    // Deep midnight-indigo gradient fill
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.05, green: 0.07, blue: 0.16, alpha: 1.0),
        CGColor(red: 0.09, green: 0.06, blue: 0.22, alpha: 1.0),
        CGColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 1.0)
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0])!
    cg.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )

    // Radial cyan/indigo aura core glow
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let glowColors = [
        CGColor(red: 0.16, green: 0.85, blue: 0.96, alpha: 0.45),
        CGColor(red: 0.42, green: 0.36, blue: 0.98, alpha: 0.22),
        CGColor(red: 0.16, green: 0.88, blue: 0.65, alpha: 0.0)
    ] as CFArray
    let radialGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 0.5, 1.0])!
    cg.drawRadialGradient(
        radialGrad,
        startCenter: center,
        startRadius: s * 0.02,
        endCenter: center,
        endRadius: s * 0.42,
        options: []
    )

    // Concentric Aura Radar Rings
    let ringRadii: [CGFloat] = [s * 0.17, s * 0.25, s * 0.33]
    let ringColors: [NSColor] = [
        NSColor(calibratedRed: 0.16, green: 0.88, blue: 0.65, alpha: 0.85),
        NSColor(calibratedRed: 0.16, green: 0.85, blue: 0.96, alpha: 0.60),
        NSColor(calibratedRed: 0.52, green: 0.42, blue: 0.98, alpha: 0.40)
    ]
    for (idx, r) in ringRadii.enumerated() {
        let ringRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let ringPath = NSBezierPath(ovalIn: ringRect)
        ringPath.lineWidth = max(s * 0.012, 1.2)
        if idx == 2 {
            let pattern: [CGFloat] = [s * 0.03, s * 0.02]
            ringPath.setLineDash(pattern, count: 2, phase: 0)
        }
        ringColors[idx].setStroke()
        ringPath.stroke()
    }

    // Orbiting BLE Satellite Dot on middle ring
    let satAngle: CGFloat = .pi * 0.25
    let satR = ringRadii[1]
    let satCenter = CGPoint(x: center.x + cos(satAngle) * satR, y: center.y + sin(satAngle) * satR)
    let satDotRadius = s * 0.032
    let satPath = NSBezierPath(ovalIn: CGRect(
        x: satCenter.x - satDotRadius,
        y: satCenter.y - satDotRadius,
        width: satDotRadius * 2,
        height: satDotRadius * 2
    ))
    NSColor(calibratedRed: 0.16, green: 0.92, blue: 0.72, alpha: 1.0).setFill()
    satPath.fill()

    // Central Lock + Radar Core Disc
    let coreR = s * 0.115
    let coreRect = CGRect(x: center.x - coreR, y: center.y - coreR, width: coreR * 2, height: coreR * 2)
    let corePath = NSBezierPath(ovalIn: coreRect)
    NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.22, alpha: 0.95).setFill()
    corePath.fill()
    corePath.lineWidth = max(s * 0.014, 1.5)
    NSColor(calibratedRed: 0.22, green: 0.88, blue: 0.98, alpha: 1.0).setStroke()
    corePath.stroke()

    // Draw Lock Body & Shackle inside Core Disc
    let bodyW = s * 0.095
    let bodyH = s * 0.075
    let bodyRect = CGRect(x: center.x - bodyW / 2, y: center.y - bodyH * 0.65, width: bodyW, height: bodyH)
    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: s * 0.018, yRadius: s * 0.018)
    NSColor.white.setFill()
    bodyPath.fill()

    let shackleR = bodyW * 0.30
    let shacklePath = NSBezierPath()
    shacklePath.appendArc(
        withCenter: CGPoint(x: center.x, y: bodyRect.maxY + shackleR * 0.15),
        radius: shackleR,
        startAngle: 0,
        endAngle: 180,
        clockwise: false
    )
    shacklePath.lineWidth = max(s * 0.016, 1.5)
    shacklePath.lineCapStyle = .round
    NSColor(calibratedRed: 0.22, green: 0.92, blue: 0.82, alpha: 1.0).setStroke()
    shacklePath.stroke()

    // Inner Glass Rim Border
    squircle.lineWidth = max(s * 0.012, 1.0)
    NSColor(calibratedWhite: 1.0, alpha: 0.22).setStroke()
    squircle.stroke()

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - 2. Generate Custom-Vibe DMG Installer Window Background (660x440 @1x & @2x)

func renderDMGBackground(scale: CGFloat) -> NSBitmapImageRep {
    let logicalW: CGFloat = 660
    let logicalH: CGFloat = 440
    let pw = Int(logicalW * scale)
    let ph = Int(logicalH * scale)

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pw,
        pixelsHigh: ph,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: logicalW, height: logicalH)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: scale, y: scale)

    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // 1. Deep Obsidian-Indigo Aura Background Gradient
    let bgColors = [
        CGColor(red: 0.04, green: 0.05, blue: 0.11, alpha: 1.0),
        CGColor(red: 0.07, green: 0.06, blue: 0.18, alpha: 1.0),
        CGColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1.0)
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.5, 1.0])!
    cg.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: 0, y: logicalH),
        end: CGPoint(x: logicalW, y: 0),
        options: []
    )

    // 2. Ambient Dual Aura Radial Glows behind Left (App) and Right (Applications) Pedestals
    // Note: Finder coordinate (x, y_top) corresponds to CoreGraphics (x, logicalH - y_top)
    let leftCenter = CGPoint(x: 175, y: logicalH - 220)
    let rightCenter = CGPoint(x: 485, y: logicalH - 220)
    let centerPoint = CGPoint(x: 330, y: logicalH - 220)

    let leftGlow = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.16, green: 0.85, blue: 0.96, alpha: 0.26),
            CGColor(red: 0.42, green: 0.36, blue: 0.98, alpha: 0.08),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    cg.drawRadialGradient(leftGlow, startCenter: leftCenter, startRadius: 5, endCenter: leftCenter, endRadius: 170, options: [])

    let rightGlow = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.16, green: 0.88, blue: 0.65, alpha: 0.22),
            CGColor(red: 0.25, green: 0.58, blue: 1.0, alpha: 0.08),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    cg.drawRadialGradient(rightGlow, startCenter: rightCenter, startRadius: 5, endCenter: rightCenter, endRadius: 170, options: [])

    // 3. Concentric Aura Radar Rings centered across the canvas
    for idx in 0..<5 {
        let r = CGFloat(90 + idx * 55)
        let ringRect = CGRect(x: centerPoint.x - r, y: centerPoint.y - r, width: r * 2, height: r * 2)
        let ringPath = NSBezierPath(ovalIn: ringRect)
        ringPath.lineWidth = 1.0
        NSColor(calibratedRed: 0.22, green: 0.82, blue: 0.96, alpha: CGFloat(0.14 - Double(idx) * 0.022)).setStroke()
        ringPath.stroke()
    }

    // 4. Translucent Glass Pedestal Cards for AuraSense.app and /Applications
    func drawPedestal(center: CGPoint, borderTint: NSColor, badgeText: String) {
        let w: CGFloat = 156
        let h: CGFloat = 166
        let cardRect = CGRect(x: center.x - w / 2, y: center.y - h / 2 - 6, width: w, height: h)
        let path = NSBezierPath(roundedRect: cardRect, xRadius: 22, yRadius: 22)
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.22, alpha: 0.65).setFill()
        path.fill()
        path.lineWidth = 1.5
        borderTint.setStroke()
        path.stroke()

        // Subtle top pill label above pedestal
        let pillAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: borderTint.withAlphaComponent(0.95),
            .kern: 1.1
        ]
        let attrStr = NSAttributedString(string: badgeText, attributes: pillAttrs)
        let strSize = attrStr.size()
        attrStr.draw(at: CGPoint(x: center.x - strSize.width / 2, y: cardRect.maxY + 8))
    }

    drawPedestal(
        center: leftCenter,
        borderTint: NSColor(calibratedRed: 0.16, green: 0.85, blue: 0.96, alpha: 0.55),
        badgeText: "AURASENSE APP"
    )
    drawPedestal(
        center: rightCenter,
        borderTint: NSColor(calibratedRed: 0.16, green: 0.88, blue: 0.65, alpha: 0.55),
        badgeText: "MACOS APPLICATIONS"
    )

    // 5. Glowing Neon Chevron Track between Left and Right Pedestals
    let chevronY = centerPoint.y
    for i in -2...2 {
        let cx = centerPoint.x + CGFloat(i * 20)
        let alpha = 0.35 + CGFloat(i + 2) * 0.15
        let chev = NSBezierPath()
        chev.move(to: CGPoint(x: cx - 5, y: chevronY + 9))
        chev.line(to: CGPoint(x: cx + 5, y: chevronY))
        chev.line(to: CGPoint(x: cx - 5, y: chevronY - 9))
        chev.lineWidth = 2.6
        chev.lineCapStyle = .round
        chev.lineJoinStyle = .round
        NSColor(calibratedRed: 0.16, green: 0.88, blue: 0.82, alpha: alpha).setStroke()
        chev.stroke()
    }

    let dragCaption = NSAttributedString(
        string: "DRAG TO INSTALL",
        attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 0.85),
            .kern: 1.4
        ]
    )
    let dragSize = dragCaption.size()
    dragCaption.draw(at: CGPoint(x: centerPoint.x - dragSize.width / 2, y: chevronY - 28))

    // 6. Top Brand Header ("AuraSense" + Subtitle)
    let titleStr = NSAttributedString(
        string: "AuraSense",
        attributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold),
            .foregroundColor: NSColor.white
        ]
    )
    let titleSize = titleStr.size()
    titleStr.draw(at: CGPoint(x: centerPoint.x - titleSize.width / 2, y: logicalH - 62))

    let subStr = NSAttributedString(
        string: "BLE Proximity Lock & Accessibility Auto-Unlock for macOS",
        attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(calibratedRed: 0.68, green: 0.82, blue: 0.98, alpha: 0.90)
        ]
    )
    let subSize = subStr.size()
    subStr.draw(at: CGPoint(x: centerPoint.x - subSize.width / 2, y: logicalH - 86))

    // 7. Bottom Footer Dock for Guided Setup & Telemetry Info
    let footerRect = CGRect(x: 95, y: 24, width: logicalW - 190, height: 44)
    let footerPath = NSBezierPath(roundedRect: footerRect, xRadius: 14, yRadius: 14)
    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.20, alpha: 0.78).setFill()
    footerPath.fill()
    footerPath.lineWidth = 1.0
    NSColor(calibratedRed: 0.38, green: 0.48, blue: 0.88, alpha: 0.38).setStroke()
    footerPath.stroke()

    let footerText = NSAttributedString(
        string: "✦  Drag AuraSense.app into Applications, or open Install AuraSense for guided setup  ✦",
        attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.90, alpha: 0.92)
        ]
    )
    let fSize = footerText.size()
    footerText.draw(at: CGPoint(x: centerPoint.x - fSize.width / 2, y: footerRect.midY - fSize.height / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Main Execution

let fm = FileManager.default
let currentDir = fm.currentDirectoryPath
let resourcesDir = "\(currentDir)/Resources"
let iconsetDir = "/tmp/AppIcon.iconset"

try? fm.removeItem(atPath: iconsetDir)
try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
try fm.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)

let iconSpecs: [(String, Int, Int)] = [
    ("icon_16x16.png", 16, 16),
    ("icon_16x16@2x.png", 32, 16),
    ("icon_32x32.png", 32, 32),
    ("icon_32x32@2x.png", 64, 32),
    ("icon_128x128.png", 128, 128),
    ("icon_128x128@2x.png", 256, 128),
    ("icon_256x256.png", 256, 256),
    ("icon_256x256@2x.png", 512, 256),
    ("icon_512x512.png", 512, 512),
    ("icon_512x512@2x.png", 1024, 512)
]

for (filename, px, pt) in iconSpecs {
    let rep = renderAppIcon(pixelSize: px, pointSize: pt)
    try savePNG(rep, to: "\(iconsetDir)/\(filename)")
}

// Write Resources/AppIcon.icns directly via ImageIO CGImageDestination
let icnsURL = URL(fileURLWithPath: "\(resourcesDir)/AppIcon.icns")
let icnsSizes = [16, 32, 64, 128, 256, 512, 1024]
if let dest = CGImageDestinationCreateWithURL(icnsURL as CFURL, "com.apple.icns" as CFString, icnsSizes.count, nil) {
    for sz in icnsSizes {
        let rep = renderAppIcon(pixelSize: sz, pointSize: sz)
        if let cgImg = rep.cgImage {
            CGImageDestinationAddImage(dest, cgImg, nil)
        }
    }
    CGImageDestinationFinalize(dest)
}
let masterIcon = renderAppIcon(pixelSize: 1024, pointSize: 1024)
try savePNG(masterIcon, to: "\(resourcesDir)/AppIcon.png")

// Render DMG Custom Installer Backgrounds (@1x and @2x)
let dmg1x = renderDMGBackground(scale: 1.0)
try savePNG(dmg1x, to: "\(resourcesDir)/dmg_background.png")

let dmg2x = renderDMGBackground(scale: 2.0)
try savePNG(dmg2x, to: "\(resourcesDir)/dmg_background@2x.png")

print("Generated Resources/AppIcon.icns, dmg_background.png, and dmg_background@2x.png successfully.")
