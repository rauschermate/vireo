#!/usr/bin/env swift
// Builds Resources/AppIcon.icns from the designed artwork in
// Resources/AppIcon-source.png (a finished rounded-square macOS icon: teal/green
// "V" bird glyph on a dark body). The source is aspect-fit onto a square canvas
// so a non-square export isn't distorted. Run from the repo root:
//   swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024
let sourcePath = "Resources/AppIcon-source.png"

guard let source = NSImage(contentsOfFile: sourcePath) else {
    fatalError("missing \(sourcePath)")
}

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
    ctx.imageInterpolation = .high

    // Aspect-fit the artwork onto the square canvas (transparent letterbox for a
    // non-square source; the art already carries its own rounded-rect + margin).
    let s = source.size
    let scale = min(canvas / s.width, canvas / s.height)
    let w = s.width * scale, h = s.height * scale
    let origin = NSPoint(x: (canvas - w) / 2, y: (canvas - h) / 2)
    source.draw(in: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                from: .zero, operation: .sourceOver, fraction: 1)

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
