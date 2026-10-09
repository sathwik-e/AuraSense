import AppKit

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let canvas = NSRect(origin: .zero, size: size)
let backgroundShape = NSBezierPath(roundedRect: canvas.insetBy(dx: 24, dy: 24), xRadius: 218, yRadius: 218)
backgroundShape.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.025, green: 0.09, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.035, green: 0.19, blue: 0.31, alpha: 1),
    NSColor(calibratedRed: 0.02, green: 0.075, blue: 0.16, alpha: 1)
])!.draw(in: canvas, angle: 34)

NSColor(calibratedRed: 0.10, green: 0.75, blue: 0.88, alpha: 0.09).setFill()
NSBezierPath(ovalIn: NSRect(x: 585, y: 230, width: 570, height: 570)).fill()
for radius in stride(from: 420, through: 590, by: 58) {
    let ring = NSBezierPath(ovalIn: NSRect(x: 512 - radius / 2, y: 512 - radius / 2, width: radius, height: radius))
    ring.lineWidth = 2
    NSColor(calibratedRed: 0.33, green: 0.77, blue: 0.91, alpha: 0.18).setStroke()
    ring.stroke()
}

let phone = NSBezierPath(roundedRect: NSRect(x: 270, y: 168, width: 365, height: 690), xRadius: 62, yRadius: 62)
NSColor(calibratedRed: 0.03, green: 0.13, blue: 0.23, alpha: 0.98).setFill()
phone.fill()
NSColor(calibratedRed: 0.64, green: 0.91, blue: 0.97, alpha: 0.96).setStroke()
phone.lineWidth = 22
phone.stroke()

NSColor(calibratedRed: 0.48, green: 0.83, blue: 0.91, alpha: 0.9).setFill()
NSBezierPath(roundedRect: NSRect(x: 395, y: 790, width: 116, height: 12), xRadius: 6, yRadius: 6).fill()
NSBezierPath(ovalIn: NSRect(x: 440, y: 202, width: 24, height: 24)).fill()

let lockShackle = NSBezierPath()
lockShackle.lineWidth = 28
lockShackle.lineCapStyle = .round
lockShackle.appendArc(withCenter: NSPoint(x: 655, y: 510), radius: 103, startAngle: 0, endAngle: 180)
NSColor(calibratedRed: 0.43, green: 0.91, blue: 0.91, alpha: 1).setStroke()
lockShackle.stroke()

let lockBody = NSBezierPath(roundedRect: NSRect(x: 525, y: 330, width: 260, height: 210), xRadius: 42, yRadius: 42)
NSGradient(colors: [
    NSColor(calibratedRed: 0.34, green: 0.91, blue: 0.88, alpha: 1),
    NSColor(calibratedRed: 0.18, green: 0.65, blue: 0.83, alpha: 1)
])!.draw(in: lockBody, angle: 90)
NSColor(calibratedRed: 0.75, green: 0.98, blue: 0.98, alpha: 0.8).setStroke()
lockBody.lineWidth = 5
lockBody.stroke()

NSColor(calibratedRed: 0.02, green: 0.17, blue: 0.28, alpha: 0.9).setFill()
NSBezierPath(ovalIn: NSRect(x: 636, y: 425, width: 38, height: 38)).fill()
NSBezierPath(roundedRect: NSRect(x: 648, y: 390, width: 14, height: 58), xRadius: 7, yRadius: 7).fill()

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render AuraSense app icon")
}
try png.write(to: outputURL, options: .atomic)
