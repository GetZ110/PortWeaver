import AppKit
let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.10, green: 0.29, blue: 0.58, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 205, yRadius: 205).fill()
let white = NSColor.white
white.setStroke()
let line = NSBezierPath(); line.lineWidth = 62; line.lineCapStyle = .round; line.lineJoinStyle = .round
line.move(to: NSPoint(x: 260, y: 635)); line.line(to: NSPoint(x: 765, y: 635))
line.move(to: NSPoint(x: 660, y: 740)); line.line(to: NSPoint(x: 765, y: 635)); line.line(to: NSPoint(x: 660, y: 530))
line.move(to: NSPoint(x: 764, y: 390)); line.line(to: NSPoint(x: 260, y: 390))
line.move(to: NSPoint(x: 365, y: 495)); line.line(to: NSPoint(x: 260, y: 390)); line.line(to: NSPoint(x: 365, y: 285))
line.stroke()
image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
