import AppKit

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let canvasSize = NSSize(width: 720, height: 500)
let artwork = NSImage(size: canvasSize)
artwork.lockFocus()

let bounds = NSRect(origin: .zero, size: canvasSize)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.035, green: 0.075, blue: 0.15, alpha: 1),
    NSColor(calibratedRed: 0.055, green: 0.13, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.025, green: 0.07, blue: 0.13, alpha: 1)
])!
gradient.draw(in: bounds, angle: 28)

NSColor(calibratedRed: 0.05, green: 0.78, blue: 0.88, alpha: 0.10).setFill()
NSBezierPath(ovalIn: NSRect(x: 470, y: 80, width: 340, height: 340)).fill()
NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.95, alpha: 0.08).setFill()
NSBezierPath(ovalIn: NSRect(x: -140, y: 180, width: 360, height: 360)).fill()

for index in 0..<4 {
    let ring = NSBezierPath(ovalIn: NSRect(x: 500 + index * 24, y: 164 + index * 24, width: 190 - index * 48, height: 190 - index * 48))
    ring.lineWidth = 1
    NSColor(calibratedRed: 0.36, green: 0.85, blue: 0.92, alpha: 0.12).setStroke()
    ring.stroke()
}

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 27, weight: .semibold),
    .foregroundColor: NSColor.white
]
let eyebrowAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.39, green: 0.88, blue: 0.92, alpha: 1),
    .kern: 2.4
]
let hintAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.27, alpha: 0.92)
]
(NSGradient(colors: [
    NSColor(calibratedRed: 0.91, green: 0.97, blue: 0.98, alpha: 0.94),
    NSColor(calibratedRed: 0.77, green: 0.88, blue: 0.93, alpha: 0.94)
])!).draw(in: NSBezierPath(roundedRect: NSRect(x: 38, y: 42, width: 644, height: 92), xRadius: 18, yRadius: 18), angle: 90)
("AURASENSE" as NSString).draw(at: NSPoint(x: 42, y: 438), withAttributes: titleAttributes)
("PROXIMITY, MADE PERSONAL" as NSString).draw(at: NSPoint(x: 44, y: 419), withAttributes: eyebrowAttributes)
("Drag AuraSense into Applications to install" as NSString).draw(at: NSPoint(x: 58, y: 78), withAttributes: hintAttributes)

let labelCard = NSGradient(colors: [
    NSColor(calibratedRed: 0.88, green: 0.96, blue: 0.98, alpha: 0.94),
    NSColor(calibratedRed: 0.70, green: 0.86, blue: 0.92, alpha: 0.94)
])!
for x in [105, 445] {
    labelCard.draw(in: NSBezierPath(roundedRect: NSRect(x: x, y: 148, width: 170, height: 46), xRadius: 14, yRadius: 14), angle: 90)
}

let arrow = NSBezierPath()
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 315, y: 253))
arrow.line(to: NSPoint(x: 405, y: 253))
arrow.move(to: NSPoint(x: 392, y: 266))
arrow.line(to: NSPoint(x: 405, y: 253))
arrow.line(to: NSPoint(x: 392, y: 240))
NSColor(calibratedRed: 0.43, green: 0.87, blue: 0.91, alpha: 0.9).setStroke()
arrow.stroke()

artwork.unlockFocus()
guard let tiff = artwork.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render AuraSense installer background")
}
try png.write(to: outputURL, options: .atomic)
