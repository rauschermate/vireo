#!/usr/bin/env swift
// Builds Resources/AppIcon.icns from the designed artwork in
// Resources/AppIcon-source-2.png (a finished rounded-square macOS icon: silver
// "V" bird glyph on a near-black body). The source is aspect-fit onto a square
// canvas so a non-square export isn't distorted. Run from the repo root:
//   swift scripts/make-icon.swift
// (Resources/AppIcon-source.png is the superseded teal/green original, kept for
// reference only — it is not what ships.)
import AppKit

let canvas: CGFloat = 1024
let sourcePath = "Resources/AppIcon-source-2.png"

guard let sourceData = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)),
      let sourceRep = NSBitmapImageRep(data: sourceData) else {
    fatalError("missing \(sourcePath)")
}

/// Some icon exports ship *fake* transparency: no alpha channel, with the
/// checkerboard painted in as pixels. Dropped into the icns as-is that becomes a
/// gray checkerboard behind the icon. Recover real alpha by flood-filling the
/// light background inward from the border — the artwork's antialiased rim is
/// dark enough to stop the fill, so only true background is cleared.
func makeBackgroundTransparent(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: w * 4, bitsPerPixel: 32),
          let ctx = NSGraphicsContext(bitmapImageRep: out) else { fatalError("no bitmap context") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()

    guard let px = out.bitmapData else { fatalError("no pixels") }
    let row = out.bytesPerRow
    func lum(_ i: Int) -> Double {
        (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255
    }
    func idx(_ x: Int, _ y: Int) -> Int { y * row + x * 4 }

    // Flood fill (4-connected) from every border pixel that reads as background.
    let bgFloor = 0.80          // checkerboard shades sit at 0.94 / 1.00
    var isBG = [Bool](repeating: false, count: w * h)
    var stack: [Int] = []
    func push(_ x: Int, _ y: Int) {
        guard x >= 0, x < w, y >= 0, y < h else { return }
        let n = y * w + x
        guard !isBG[n], lum(idx(x, y)) > bgFloor else { return }
        isBG[n] = true
        stack.append(n)
    }
    for x in 0..<w { push(x, 0); push(x, h - 1) }
    for y in 0..<h { push(0, y); push(w - 1, y) }
    while let n = stack.popLast() {
        let x = n % w, y = n / w
        push(x - 1, y); push(x + 1, y); push(x, y - 1); push(x, y + 1)
    }

    let cleared = isBG.lazy.filter { $0 }.count
    guard cleared > w * h / 20 else {
        fatalError("background fill found only \(cleared)px — is the source really checkerboarded?")
    }

    // The rim pixels blend artwork into that background. Rather than leave a
    // white halo, re-key each one: take the colour from its nearest artwork
    // neighbour and turn how much background it picked up into partial alpha.
    var edits: [(Int, UInt8, UInt8, UInt8, UInt8)] = []
    for y in 0..<h {
        for x in 0..<w where !isBG[y * w + x] {
            var bgSum = 0.0, bgN = 0
            var fg: Int? = nil
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                if isBG[ny * w + nx] {
                    bgSum += lum(idx(nx, ny)); bgN += 1
                } else if fg == nil, lum(idx(nx, ny)) < bgFloor {
                    // an interior neighbour, i.e. not itself a blended rim pixel
                    var rim = false
                    for (ex, ey) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let ux = nx + ex, uy = ny + ey
                        if ux >= 0, ux < w, uy >= 0, uy < h, isBG[uy * w + ux] { rim = true }
                    }
                    if !rim { fg = idx(nx, ny) }
                }
            }
            guard bgN > 0, let f = fg else { continue }
            let bgL = bgSum / Double(bgN), fgL = lum(f), obs = lum(idx(x, y))
            let coverage = bgL - fgL > 0.05 ? (bgL - obs) / (bgL - fgL) : 1
            let a = UInt8(max(0, min(1, coverage)) * 255)
            edits.append((idx(x, y), px[f], px[f + 1], px[f + 2], a))
        }
    }
    for (i, r, g, b, a) in edits { px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = a }
    for n in 0..<(w * h) where isBG[n] {
        let i = idx(n % w, n / w)
        px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
    }
    return out
}

/// Tight bounds of everything non-transparent, so the artwork — not its
/// surrounding margin — is what gets fit to the canvas.
func contentBounds(_ rep: NSBitmapImageRep) -> NSRect {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard let px = rep.bitmapData else { return NSRect(x: 0, y: 0, width: w, height: h) }
    let row = rep.bytesPerRow
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h {
        for x in 0..<w where px[y * row + x * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return NSRect(x: 0, y: 0, width: w, height: h) }
    // NSBitmapImageRep scans top-down; NSImage draws bottom-up.
    return NSRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let artRep = sourceRep.hasAlpha ? sourceRep : makeBackgroundTransparent(sourceRep)
let crop = sourceRep.hasAlpha
    ? NSRect(x: 0, y: 0, width: artRep.pixelsWide, height: artRep.pixelsHigh)
    : contentBounds(artRep)
let source = NSImage(size: NSSize(width: artRep.pixelsWide, height: artRep.pixelsHigh))
source.addRepresentation(artRep)

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
    let s = crop.size
    let scale = min(canvas / s.width, canvas / s.height)
    let w = s.width * scale, h = s.height * scale
    let origin = NSPoint(x: (canvas - w) / 2, y: (canvas - h) / 2)
    source.draw(in: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                from: crop, operation: .sourceOver, fraction: 1)

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
