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

// MARK: - Helper: Draw Neon Orbit + Eclipse Crescent + Λ U R Λ S E N S E Typography

func drawEclipseLogo(in cg: CGContext, center: CGPoint, scaleRadius: CGFloat, includeWordmark: Bool) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // 1. Subtle interior deep navy-cyan radial atmosphere inside the orbit ring
    let innerGlowColors = [
        CGColor(red: 0.04, green: 0.14, blue: 0.32, alpha: 0.55),
        CGColor(red: 0.02, green: 0.06, blue: 0.16, alpha: 0.35),
        CGColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 0.0)
    ] as CFArray
    if let innerGrad = CGGradient(colorsSpace: colorSpace, colors: innerGlowColors, locations: [0.0, 0.65, 1.0]) {
        cg.drawRadialGradient(
            innerGrad,
            startCenter: CGPoint(x: center.x, y: center.y + scaleRadius * 0.08),
            startRadius: scaleRadius * 0.02,
            endCenter: center,
            endRadius: scaleRadius * 0.98,
            options: []
        )
    }

    // 2. Outer Neon Orbit Ring with multi-layer bloom glow
    let orbitRect = CGRect(
        x: center.x - scaleRadius,
        y: center.y - scaleRadius,
        width: scaleRadius * 2,
        height: scaleRadius * 2
    )

    let glowPasses: [(CGFloat, CGFloat)] = [
        (scaleRadius * 0.085, 0.12),
        (scaleRadius * 0.048, 0.25),
        (scaleRadius * 0.026, 0.45)
    ]
    for (lineW, alpha) in glowPasses {
        cg.saveGState()
        cg.setLineWidth(max(lineW, 1.0))
        cg.setStrokeColor(CGColor(red: 0.20, green: 0.78, blue: 1.00, alpha: alpha))
        cg.strokeEllipse(in: orbitRect)
        cg.restoreGState()
    }

    // Main crisp gradient stroke for the outer Neon Orbit ring
    cg.saveGState()
    cg.addEllipse(in: orbitRect)
    cg.setLineWidth(max(scaleRadius * 0.018, 1.3))
    cg.replacePathWithStrokedPath()
    cg.clip()
    let orbitGradColors = [
        CGColor(red: 0.12, green: 0.36, blue: 0.98, alpha: 1.0),
        CGColor(red: 0.26, green: 0.80, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.24, green: 0.96, blue: 0.92, alpha: 1.0)
    ] as CFArray
    if let orbitGrad = CGGradient(colorsSpace: colorSpace, colors: orbitGradColors, locations: [0.0, 0.55, 1.0]) {
        cg.drawLinearGradient(
            orbitGrad,
            start: CGPoint(x: orbitRect.minX, y: orbitRect.midY),
            end: CGPoint(x: orbitRect.maxX, y: orbitRect.midY),
            options: []
        )
    }
    cg.restoreGState()

    // 3. Inner Solar/Lunar Eclipse Crescent Arc
    let eclipseCenterY = includeWordmark ? (center.y + scaleRadius * 0.10) : center.y
    let sunR = scaleRadius * 0.44
    let moonR = sunR * 0.945
    let sunCenter = CGPoint(x: center.x, y: eclipseCenterY)
    let moonCenter = CGPoint(x: center.x - sunR * 0.115, y: eclipseCenterY - sunR * 0.155)

    // Corona bloom behind the upper-right rim of the eclipse
    let coronaCenter = CGPoint(x: sunCenter.x + sunR * 0.22, y: sunCenter.y + sunR * 0.32)
    let coronaColors = [
        CGColor(red: 0.32, green: 0.86, blue: 1.00, alpha: 0.50),
        CGColor(red: 0.14, green: 0.48, blue: 0.98, alpha: 0.18),
        CGColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 0.0)
    ] as CFArray
    if let coronaGrad = CGGradient(colorsSpace: colorSpace, colors: coronaColors, locations: [0.0, 0.45, 1.0]) {
        cg.drawRadialGradient(
            coronaGrad,
            startCenter: coronaCenter,
            startRadius: sunR * 0.05,
            endCenter: sunCenter,
            endRadius: sunR * 1.35,
            options: []
        )
    }

    // Even-Odd Eclipse Crescent Path
    cg.saveGState()
    let crescentPath = CGMutablePath()
    crescentPath.addEllipse(in: CGRect(x: sunCenter.x - sunR, y: sunCenter.y - sunR, width: sunR * 2, height: sunR * 2))
    crescentPath.addEllipse(in: CGRect(x: moonCenter.x - moonR, y: moonCenter.y - moonR, width: moonR * 2, height: moonR * 2))
    cg.addPath(crescentPath)
    cg.clip(using: .evenOdd)

    let crescentColors = [
        CGColor(red: 0.10, green: 0.38, blue: 0.98, alpha: 0.95),
        CGColor(red: 0.32, green: 0.84, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.92, green: 0.99, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.28, green: 0.86, blue: 1.00, alpha: 0.98)
    ] as CFArray
    if let crescentGrad = CGGradient(colorsSpace: colorSpace, colors: crescentColors, locations: [0.0, 0.45, 0.74, 1.0]) {
        cg.drawLinearGradient(
            crescentGrad,
            start: CGPoint(x: sunCenter.x - sunR, y: sunCenter.y - sunR * 0.2),
            end: CGPoint(x: sunCenter.x + sunR * 0.85, y: sunCenter.y + sunR * 0.85),
            options: []
        )
    }
    cg.restoreGState()

    // 4. Geometric Typography: "Λ U R Λ S E N S E"
    if includeWordmark && scaleRadius >= 24 {
        let fontSize = max(scaleRadius * 0.125, 6.0)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .light)
        let kern = fontSize * 0.46

        let fullStr = NSMutableAttributedString()
        let auraPart = NSAttributedString(
            string: "ΛURΛ",
            attributes: [
                .font: font,
                .foregroundColor: NSColor(calibratedRed: 0.96, green: 0.98, blue: 1.0, alpha: 0.98),
                .kern: kern
            ]
        )
        let sensePart = NSAttributedString(
            string: "SENSE",
            attributes: [
                .font: font,
                .foregroundColor: NSColor(calibratedRed: 0.26, green: 0.84, blue: 1.0, alpha: 0.98),
                .kern: kern
            ]
        )
        fullStr.append(auraPart)
        fullStr.append(sensePart)

        let textSize = fullStr.size()
        let textOrigin = CGPoint(
            x: center.x - textSize.width / 2 + kern * 0.4,
            y: center.y - scaleRadius * 0.39 - textSize.height / 2
        )
        fullStr.draw(at: textOrigin)
    }
}

// MARK: - 1. Generate AppIcon (macOS Squircle with Neon Orbit, Eclipse & Λ U R Λ S E N S E)

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
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225

    cg.saveGState()
    let squircle = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    squircle.addClip()

    // Pitch-black obsidian background matching the uploaded Neon Orbit logo
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.01, green: 0.01, blue: 0.02, alpha: 1.0),
        CGColor(red: 0.02, green: 0.04, blue: 0.09, alpha: 1.0),
        CGColor(red: 0.00, green: 0.01, blue: 0.02, alpha: 1.0)
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.5, 1.0])!
    cg.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )

    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let orbitRadius = rect.width * 0.415
    drawEclipseLogo(in: cg, center: center, scaleRadius: orbitRadius, includeWordmark: pixelSize >= 64)

    // Subtle dark glass squircle border
    squircle.lineWidth = max(s * 0.010, 1.0)
    NSColor(calibratedRed: 0.22, green: 0.78, blue: 1.0, alpha: 0.22).setStroke()
    squircle.stroke()

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - 2. Generate Custom DMG Installer Window Background (660x440 @1x & @2x)

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

    // 1. Deep Pitch-Black to Midnight Eclipse Background
    let bgColors = [
        CGColor(red: 0.01, green: 0.02, blue: 0.05, alpha: 1.0),
        CGColor(red: 0.03, green: 0.06, blue: 0.14, alpha: 1.0),
        CGColor(red: 0.01, green: 0.01, blue: 0.03, alpha: 1.0)
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.5, 1.0])!
    cg.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: 0, y: logicalH),
        end: CGPoint(x: logicalW, y: 0),
        options: []
    )

    let leftCenter = CGPoint(x: 175, y: logicalH - 220)
    let rightCenter = CGPoint(x: 485, y: logicalH - 220)
    let centerPoint = CGPoint(x: 330, y: logicalH - 220)

    // 2. Subtle Eclipse Orbit Rings in Center
    for idx in 0..<4 {
        let r = CGFloat(95 + idx * 58)
        let ringRect = CGRect(x: centerPoint.x - r, y: centerPoint.y - r, width: r * 2, height: r * 2)
        let ringPath = NSBezierPath(ovalIn: ringRect)
        ringPath.lineWidth = 1.0
        NSColor(calibratedRed: 0.20, green: 0.78, blue: 1.0, alpha: CGFloat(0.14 - Double(idx) * 0.028)).setStroke()
        ringPath.stroke()
    }

    // 3. Pedestal Cards
    func drawPedestal(center: CGPoint, borderTint: NSColor, badgeText: String) {
        let w: CGFloat = 156
        let h: CGFloat = 166
        let cardRect = CGRect(x: center.x - w / 2, y: center.y - h / 2 - 6, width: w, height: h)
        let path = NSBezierPath(roundedRect: cardRect, xRadius: 22, yRadius: 22)
        NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.15, alpha: 0.78).setFill()
        path.fill()
        path.lineWidth = 1.4
        borderTint.setStroke()
        path.stroke()

        let pillAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: borderTint.withAlphaComponent(0.95),
            .kern: 1.4
        ]
        let attrStr = NSAttributedString(string: badgeText, attributes: pillAttrs)
        let strSize = attrStr.size()
        attrStr.draw(at: CGPoint(x: center.x - strSize.width / 2, y: cardRect.maxY + 8))
    }

    drawPedestal(
        center: leftCenter,
        borderTint: NSColor(calibratedRed: 0.22, green: 0.84, blue: 1.0, alpha: 0.55),
        badgeText: "AURASENSE 1.0"
    )
    drawPedestal(
        center: rightCenter,
        borderTint: NSColor(calibratedRed: 0.18, green: 0.58, blue: 1.0, alpha: 0.55),
        badgeText: "APPLICATIONS"
    )

    // 4. Neon Chevron Track
    let chevronY = centerPoint.y
    for i in -2...2 {
        let cx = centerPoint.x + CGFloat(i * 20)
        let alpha = 0.35 + CGFloat(i + 2) * 0.15
        let chev = NSBezierPath()
        chev.move(to: CGPoint(x: cx - 5, y: chevronY + 9))
        chev.line(to: CGPoint(x: cx + 5, y: chevronY))
        chev.line(to: CGPoint(x: cx - 5, y: chevronY - 9))
        chev.lineWidth = 2.4
        chev.lineCapStyle = .round
        chev.lineJoinStyle = .round
        NSColor(calibratedRed: 0.24, green: 0.86, blue: 1.0, alpha: alpha).setStroke()
        chev.stroke()
    }

    // 5. Top Brand Wordmark ("Λ U R Λ S E N S E")
    let brandFont = NSFont.systemFont(ofSize: 26, weight: .light)
    let brandStr = NSMutableAttributedString()
    brandStr.append(NSAttributedString(
        string: "Λ U R Λ ",
        attributes: [
            .font: brandFont,
            .foregroundColor: NSColor.white,
            .kern: 4.5
        ]
    ))
    brandStr.append(NSAttributedString(
        string: "S E N S E",
        attributes: [
            .font: brandFont,
            .foregroundColor: NSColor(calibratedRed: 0.26, green: 0.84, blue: 1.0, alpha: 1.0),
            .kern: 4.5
        ]
    ))
    let titleSize = brandStr.size()
    brandStr.draw(at: CGPoint(x: centerPoint.x - titleSize.width / 2, y: logicalH - 60))

    let subStr = NSAttributedString(
        string: "BLE Proximity Lock & Instant Keychain Auto-Fill for macOS (v1.0)",
        attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.68, green: 0.84, blue: 0.98, alpha: 0.88)
        ]
    )
    let subSize = subStr.size()
    subStr.draw(at: CGPoint(x: centerPoint.x - subSize.width / 2, y: logicalH - 84))

    // 6. Simple Bottom Instruction Bar
    let footerRect = CGRect(x: 110, y: 24, width: logicalW - 220, height: 40)
    let footerPath = NSBezierPath(roundedRect: footerRect, xRadius: 12, yRadius: 12)
    NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.18, alpha: 0.82).setFill()
    footerPath.fill()
    footerPath.lineWidth = 1.0
    NSColor(calibratedRed: 0.22, green: 0.78, blue: 1.0, alpha: 0.35).setStroke()
    footerPath.stroke()

    let footerText = NSAttributedString(
        string: "Drag AuraSense.app to Applications to install",
        attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 0.95)
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

let dmg1x = renderDMGBackground(scale: 1.0)
try savePNG(dmg1x, to: "\(resourcesDir)/dmg_background.png")

let dmg2x = renderDMGBackground(scale: 2.0)
try savePNG(dmg2x, to: "\(resourcesDir)/dmg_background@2x.png")

print("Generated Neon Orbit Eclipse AppIcon.icns, dmg_background.png, and dmg_background@2x.png successfully.")
