import ImageIO
import Foundation
import AppKit
import CoreGraphics

// MARK: - Helper to save NSBitmapImageRep as PNG

func pngData(from rep: NSBitmapImageRep) throws -> Data {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AuraAssetGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    return data
}

func savePNG(_ rep: NSBitmapImageRep, to path: String) throws {
    let data = try pngData(from: rep)
    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: - Direct Apple .icns Binary Builder (Supports all @1x and @2x Retina chunks)

func writeAppleICNSFile(chunks: [(String, Data)], to path: String) throws {
    var body = Data()
    for (osType, pngBytes) in chunks {
        let typeBytes = Array(osType.utf8)
        guard typeBytes.count == 4 else { continue }
        var chunkLen = UInt32(8 + pngBytes.count).bigEndian
        body.append(contentsOf: typeBytes)
        withUnsafeBytes(of: &chunkLen) { body.append(contentsOf: $0) }
        body.append(pngBytes)
    }

    var fileData = Data()
    fileData.append(contentsOf: Array("icns".utf8))
    var totalLen = UInt32(8 + body.count).bigEndian
    withUnsafeBytes(of: &totalLen) { fileData.append(contentsOf: $0) }
    fileData.append(body)

    try fileData.write(to: URL(fileURLWithPath: path))
}

// MARK: - Draw Neon Orbit + True Subtracted Eclipse Crescent + Λ U R Λ S E N S E Typography

func drawEclipseLogo(in cg: CGContext, center: CGPoint, scaleRadius: CGFloat, includeWordmark: Bool) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // 1. Deep sapphire-navy atmospheric glow inside the orbit ring
    let innerGlowColors = [
        CGColor(red: 0.05, green: 0.16, blue: 0.36, alpha: 0.65),
        CGColor(red: 0.02, green: 0.07, blue: 0.18, alpha: 0.40),
        CGColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 0.0)
    ] as CFArray
    if let innerGrad = CGGradient(colorsSpace: colorSpace, colors: innerGlowColors, locations: [0.0, 0.62, 1.0]) {
        cg.drawRadialGradient(
            innerGrad,
            startCenter: CGPoint(x: center.x, y: center.y + scaleRadius * 0.10),
            startRadius: 0.0,
            endCenter: center,
            endRadius: scaleRadius * 0.98,
            options: [.drawsBeforeStartLocation]
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
        (scaleRadius * 0.095, 0.14),
        (scaleRadius * 0.052, 0.28),
        (scaleRadius * 0.028, 0.50)
    ]
    for (lineW, alpha) in glowPasses {
        cg.saveGState()
        cg.setLineWidth(max(lineW, 1.0))
        cg.setStrokeColor(CGColor(red: 0.20, green: 0.80, blue: 1.00, alpha: alpha))
        cg.strokeEllipse(in: orbitRect)
        cg.restoreGState()
    }

    // Main crisp gradient stroke for the outer Neon Orbit ring
    cg.saveGState()
    cg.addEllipse(in: orbitRect)
    cg.setLineWidth(max(scaleRadius * 0.022, 1.4))
    cg.replacePathWithStrokedPath()
    cg.clip()
    let orbitGradColors = [
        CGColor(red: 0.12, green: 0.36, blue: 0.98, alpha: 1.0),
        CGColor(red: 0.24, green: 0.78, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.22, green: 0.96, blue: 0.92, alpha: 1.0)
    ] as CFArray
    if let orbitGrad = CGGradient(colorsSpace: colorSpace, colors: orbitGradColors, locations: [0.0, 0.52, 1.0]) {
        cg.drawLinearGradient(
            orbitGrad,
            start: CGPoint(x: orbitRect.minX, y: orbitRect.midY),
            end: CGPoint(x: orbitRect.maxX, y: orbitRect.midY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    cg.restoreGState()

    // 3. Inner Solar/Lunar Eclipse Crescent Arc using a Transparency Layer + .clear subtraction
    let eclipseCenterY = includeWordmark ? (center.y + scaleRadius * 0.11) : center.y
    let sunR = scaleRadius * 0.44
    let moonR = sunR * 0.945
    let sunCenter = CGPoint(x: center.x, y: eclipseCenterY)
    let moonCenter = CGPoint(x: center.x - sunR * 0.095, y: eclipseCenterY - sunR * 0.125)

    // Soft cyan-blue corona bloom behind the upper-right crest of the eclipse
    let coronaCenter = CGPoint(x: sunCenter.x + sunR * 0.18, y: sunCenter.y + sunR * 0.28)
    let coronaColors = [
        CGColor(red: 0.30, green: 0.86, blue: 1.00, alpha: 0.48),
        CGColor(red: 0.14, green: 0.48, blue: 0.98, alpha: 0.18),
        CGColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 0.0)
    ] as CFArray
    if let coronaGrad = CGGradient(colorsSpace: colorSpace, colors: coronaColors, locations: [0.0, 0.45, 1.0]) {
        cg.drawRadialGradient(
            coronaGrad,
            startCenter: coronaCenter,
            startRadius: 0.0,
            endCenter: sunCenter,
            endRadius: sunR * 1.32,
            options: [.drawsBeforeStartLocation]
        )
    }

    // Isolated transparency layer: draw Sun circle with gradient, then punch out Moon circle with .clear
    cg.saveGState()
    cg.beginTransparencyLayer(auxiliaryInfo: nil)

    cg.saveGState()
    cg.addEllipse(in: CGRect(x: sunCenter.x - sunR, y: sunCenter.y - sunR, width: sunR * 2, height: sunR * 2))
    cg.clip()
    let crescentColors = [
        CGColor(red: 0.10, green: 0.38, blue: 0.98, alpha: 1.0),
        CGColor(red: 0.30, green: 0.82, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.94, green: 0.99, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.28, green: 0.86, blue: 1.00, alpha: 1.0)
    ] as CFArray
    if let crescentGrad = CGGradient(colorsSpace: colorSpace, colors: crescentColors, locations: [0.0, 0.45, 0.76, 1.0]) {
        cg.drawLinearGradient(
            crescentGrad,
            start: CGPoint(x: sunCenter.x - sunR, y: sunCenter.y - sunR * 0.15),
            end: CGPoint(x: sunCenter.x + sunR * 0.85, y: sunCenter.y + sunR * 0.85),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    cg.restoreGState()

    cg.setBlendMode(.clear)
    cg.fillEllipse(in: CGRect(x: moonCenter.x - moonR, y: moonCenter.y - moonR, width: moonR * 2, height: moonR * 2))
    cg.setBlendMode(.normal)

    cg.endTransparencyLayer()
    cg.restoreGState()

    // 4. Geometric Typography: "Λ U R Λ S E N S E"
    if includeWordmark && scaleRadius >= 24 {
        let fontSize = max(scaleRadius * 0.122, 6.0)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .light)
        let kern = fontSize * 0.45

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

// MARK: - 1. Generate AppIcon (Draws in 1:1 pixel coordinates, sets pointSize after drawing)

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

    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let s = CGFloat(pixelSize)
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225

    cg.saveGState()
    let squircle = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    squircle.addClip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.00, green: 0.01, blue: 0.02, alpha: 1.0),
        CGColor(red: 0.01, green: 0.03, blue: 0.08, alpha: 1.0),
        CGColor(red: 0.00, green: 0.00, blue: 0.01, alpha: 1.0)
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.5, 1.0])!
    cg.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let orbitRadius = rect.width * 0.42
    drawEclipseLogo(in: cg, center: center, scaleRadius: orbitRadius, includeWordmark: pixelSize >= 64)

    squircle.lineWidth = max(s * 0.012, 1.0)
    NSColor(calibratedRed: 0.22, green: 0.78, blue: 1.0, alpha: 0.28).setStroke()
    squircle.stroke()

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    rep.size = NSSize(width: pointSize, height: pointSize)
    return rep
}

// MARK: - 2. Generate Menu Bar Eclipse Template Icons (18x18 @1x and 36x36 @2x)

enum MenuBarIconVariant {
    case active
    case locked
    case calibrating
    case paused
}

func renderMenuBarEclipsePNG(pixelSize: Int, pointSize: Int, variant: MenuBarIconVariant) -> NSBitmapImageRep {
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
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let scale = CGFloat(pixelSize) / CGFloat(pointSize)
    cg.scaleBy(x: scale, y: scale)

    let alpha: CGFloat = (variant == .paused) ? 0.50 : 1.0
    let center = CGPoint(x: CGFloat(pointSize) * 0.5, y: CGFloat(pointSize) * 0.5)
    let outerR: CGFloat = 7.3

    // 1. Outer Proximity Orbit Ring
    let orbitPath = NSBezierPath()
    if variant == .calibrating {
        orbitPath.appendArc(withCenter: center, radius: outerR, startAngle: 0, endAngle: 360)
        let dash: [CGFloat] = [2.2, 1.8]
        orbitPath.setLineDash(dash, count: 2, phase: 0)
    } else {
        orbitPath.appendArc(withCenter: center, radius: outerR, startAngle: 64, endAngle: 26, clockwise: false)
    }
    orbitPath.lineWidth = 1.4
    orbitPath.lineCapStyle = .round
    NSColor.black.withAlphaComponent(alpha).setStroke()
    orbitPath.stroke()

    // 2. Orbiting BLE Node at 45 degrees (top-right)
    let nodeAngle: CGFloat = .pi * 0.25
    let nodePt = CGPoint(x: center.x + cos(nodeAngle) * outerR, y: center.y + sin(nodeAngle) * outerR)
    let nodeR: CGFloat = (variant == .locked) ? 1.25 : 1.65
    NSColor.black.withAlphaComponent(alpha).setFill()
    NSBezierPath(ovalIn: CGRect(x: nodePt.x - nodeR, y: nodePt.y - nodeR, width: nodeR * 2, height: nodeR * 2)).fill()

    // 3. Inner Eclipse Crescent using Transparency Layer + .clear subtraction
    cg.saveGState()
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    let sunR: CGFloat = 4.6
    let moonR: CGFloat = 4.05
    let moonCenter = CGPoint(x: center.x - 1.10, y: center.y - 1.00)

    cg.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: alpha))
    cg.fillEllipse(in: CGRect(x: center.x - sunR, y: center.y - sunR, width: sunR * 2, height: sunR * 2))
    cg.setBlendMode(.clear)
    cg.fillEllipse(in: CGRect(x: moonCenter.x - moonR, y: moonCenter.y - moonR, width: moonR * 2, height: moonR * 2))
    cg.setBlendMode(.normal)
    cg.endTransparencyLayer()
    cg.restoreGState()

    if variant == .locked {
        let dotR: CGFloat = 1.15
        let dotCenter = CGPoint(x: center.x - 0.7, y: center.y - 0.7)
        NSColor.black.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR, width: dotR * 2, height: dotR * 2)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: pointSize, height: pointSize)
    return rep
}

// MARK: - 3. Generate DMG Installer Window Background (660x400 @1x & @2x)

/// Minimal, light installer artwork in the style of Apple's own disk images: a soft neutral
/// background, one thin arrow between the two icon slots and a short caption. Finder draws the
/// icons and their (dark) labels on top, so the background stays light for legibility.
/// Icon slots (Finder coordinates, from the top-left): app at (170, 190), Applications at (490, 190).
func renderDMGBackground(scale: CGFloat) -> NSBitmapImageRep {
    let logicalW: CGFloat = 660
    let logicalH: CGFloat = 400
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
    rep.size = NSSize(width: pw, height: ph)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: scale, y: scale)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.975, green: 0.975, blue: 0.980, alpha: 1.0),
        CGColor(red: 0.930, green: 0.932, blue: 0.940, alpha: 1.0)
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0])!
    cg.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: 0, y: logicalH),
        end: CGPoint(x: 0, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // Arrow between the icon slots (Cocoa y is flipped: 190 from the top).
    let arrowY = logicalH - 182
    let startX: CGFloat = 268
    let endX: CGFloat = 392
    let shaft = NSBezierPath()
    shaft.move(to: CGPoint(x: startX, y: arrowY))
    shaft.line(to: CGPoint(x: endX, y: arrowY))
    shaft.lineWidth = 1.6
    shaft.lineCapStyle = .round
    let head = NSBezierPath()
    head.move(to: CGPoint(x: endX - 9, y: arrowY + 7))
    head.line(to: CGPoint(x: endX, y: arrowY))
    head.line(to: CGPoint(x: endX - 9, y: arrowY - 7))
    head.lineWidth = 1.6
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    NSColor(calibratedWhite: 0.0, alpha: 0.28).setStroke()
    shaft.stroke()
    head.stroke()

    let caption = NSAttributedString(
        string: "Drag AuraSense to Applications to install",
        attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.0, alpha: 0.45)
        ]
    )
    let cSize = caption.size()
    caption.draw(at: CGPoint(x: (logicalW - cSize.width) / 2, y: 52))

    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: logicalW, height: logicalH)
    return rep
}

// MARK: - Main Execution

let fm = FileManager.default
let currentDir = fm.currentDirectoryPath
let resourcesDir = "\(currentDir)/Resources"
try fm.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)

let icnsSpec: [(String, Int, Int)] = [
    ("icp4", 16, 16),
    ("ic11", 32, 16),
    ("icp5", 32, 32),
    ("ic12", 64, 32),
    ("ic07", 128, 128),
    ("ic13", 256, 128),
    ("ic08", 256, 256),
    ("ic14", 512, 256),
    ("ic09", 512, 512),
    ("ic10", 1024, 512)
]

var icnsChunks: [(String, Data)] = []
for (osType, px, pt) in icnsSpec {
    let rep = renderAppIcon(pixelSize: px, pointSize: pt)
    let data = try pngData(from: rep)
    icnsChunks.append((osType, data))
}

let icnsPath = "\(resourcesDir)/AppIcon.icns"
try writeAppleICNSFile(chunks: icnsChunks, to: icnsPath)

let masterIcon = renderAppIcon(pixelSize: 1024, pointSize: 1024)
try savePNG(masterIcon, to: "\(resourcesDir)/AppIcon.png")

let variants: [(String, MenuBarIconVariant)] = [
    ("AuraEclipseTemplate", .active),
    ("AuraEclipseLockedTemplate", .locked),
    ("AuraEclipseScanTemplate", .calibrating),
    ("AuraEclipsePausedTemplate", .paused)
]
for (baseName, variant) in variants {
    let rep1x = renderMenuBarEclipsePNG(pixelSize: 18, pointSize: 18, variant: variant)
    try savePNG(rep1x, to: "\(resourcesDir)/\(baseName).png")
    let rep2x = renderMenuBarEclipsePNG(pixelSize: 36, pointSize: 18, variant: variant)
    try savePNG(rep2x, to: "\(resourcesDir)/\(baseName)@2x.png")
}

let dmg1x = renderDMGBackground(scale: 1.0)
try savePNG(dmg1x, to: "\(resourcesDir)/dmg_background.png")

let dmg2x = renderDMGBackground(scale: 2.0)
try savePNG(dmg2x, to: "\(resourcesDir)/dmg_background@2x.png")

print("Generated multi-resolution Retina AppIcon.icns, AppIcon.png, AuraEclipse*Template.png, and DMG backgrounds successfully.")
