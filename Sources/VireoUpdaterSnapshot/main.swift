import AppKit
import SwiftUI
import VireoUpdater
import VireoUpdaterUI

// Headless render of the update pill in each phase to a PNG — the same approach
// VireoSnapshot uses for the editor, since live screen capture is unavailable.
//
// Usage: swift run VireoUpdaterSnapshot <out.png> [--dark]

@MainActor
func renderPills(dark: Bool) -> NSImage {
    let states: [(String, UpdateModel)] = [
        ("available",   .preview(.available, version: "0.2.0")),
        ("checking",    .preview(.checking)),
        ("downloading", .preview(.downloading, progress: 0.62)),
        ("extracting",  .preview(.extracting)),
        ("installing",  .preview(.installing)),
        ("error",       .preview(.error, error: "The update is improperly signed.")),
    ]

    let row = HStack(alignment: .center, spacing: 22) {
        ForEach(Array(states.enumerated()), id: \.offset) { _, entry in
            VStack(spacing: 10) {
                UpdatePill(model: entry.1)
                Text(entry.0)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(28)
    .background(Color(nsColor: dark ? .init(white: 0.12, alpha: 1) : .init(white: 0.95, alpha: 1)))
    .environment(\.colorScheme, dark ? .dark : .light)

    let hosting = NSHostingView(rootView: row)
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize
    hosting.frame = CGRect(origin: .zero, size: size)

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        return NSImage(size: size)
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return image
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: VireoUpdaterSnapshot <out.png> [--dark]\n".utf8))
    exit(2)
}
let outPath = args[1]
let dark = args.contains("--dark")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let image = MainActor.assumeIsolated { renderPills(dark: dark) }
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(Int(image.size.width))×\(Int(image.size.height)))")
