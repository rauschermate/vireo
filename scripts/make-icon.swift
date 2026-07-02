#!/usr/bin/env swift
// Generates Resources/AppIcon.icns: a rounded-square deep-green gradient with
// a white bird glyph (a vireo is a songbird). Run from the repo root:
//   swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func render() -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("no bitmap context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // Big Sur-style icon: rounded rect with margins on a transparent canvas.
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    let top = NSColor(calibratedRed: 0.32, green: 0.55, blue: 0.29, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.16, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)

    // White bird glyph.
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        let scale = min(440 / size.width, 440 / size.height)
        let w = size.width * scale
        let h = size.height * scale
        let origin = NSPoint(x: (canvas - w) / 2, y: (canvas - h) / 2)
        symbol.draw(in: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let rep = render()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }

let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: "\(iconset)/icon_512x512@2x.png"))

// Downscale the 1024 master for every iconset slot.
let slots: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
]
for slot in slots {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task.arguments = ["-z", "\(slot.px)", "\(slot.px)",
                      "\(iconset)/icon_512x512@2x.png",
                      "--out", "\(iconset)/\(slot.name).png"]
    task.standardOutput = FileHandle.nullDevice
    try! task.run()
    task.waitUntilExit()
}

try? fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print("wrote Resources/AppIcon.icns")
