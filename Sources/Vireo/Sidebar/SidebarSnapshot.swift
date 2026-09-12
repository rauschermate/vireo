import AppKit
import SwiftUI
import VireoCore

/// Headless render of the sidebar to a PNG, for verifying its look without a
/// window (live screen capture is unavailable to the agent shell).
///
///     Vireo --snapshot-sidebar <folder> <out.png> [--dark] [--window]
///
/// `--window` renders the whole document window content instead of the
/// panel alone. The process exits after writing the file.
@MainActor
enum SidebarSnapshot {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot-sidebar"), args.count > flag + 2 else {
            return false
        }
        let folder = URL(fileURLWithPath: args[flag + 1]).standardizedFileURL
        let outPath = args[flag + 2]
        let dark = args.contains("--dark")
        let wholeWindow = args.contains("--window")

        let state = AppState.shared
        state.showFileSidebar = true
        state.openWorkspace(folder, revealSidebar: true)
        // Build the tree synchronously so the render sees rows.
        if let tree = try? FileTreeService().buildTree(at: folder) {
            state.rootFolder = tree
            // Expand the first folder and open the first file so the active
            // highlight, an open folder, and the chevron animation baseline show.
            if let firstFolder = tree.children?.first(where: { $0.isDirectory }) {
                state.sidebar.expand(firstFolder.url)
            }
            if let firstFile = tree.allFiles.first {
                state.requestOpen(firstFile.url)
            }
            if let pin = tree.allFiles.dropFirst().first, !state.sidebar.isPinned(pin.url) {
                state.sidebar.togglePin(pin.url)
            }
        }

        // Let asynchronous document state (statistics, parse results) settle
        // before the render.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))

        let image: NSImage
        if wholeWindow {
            image = render(DocumentWindowView().environmentObject(state),
                           size: CGSize(width: 1100, height: 720), dark: dark)
        } else {
            image = render(FileSidebar(topInset: SidebarMetrics.chromeHeight).environmentObject(state),
                           size: CGSize(width: state.sidebarWidth, height: 720), dark: dark)
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("failed to encode PNG\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: outPath))
            print("wrote \(outPath) (\(Int(image.size.width))×\(Int(image.size.height)))")
        } catch {
            FileHandle.standardError.write(Data("failed to write \(outPath): \(error)\n".utf8))
            exit(1)
        }
        return true
    }

    private static func render<V: View>(_ view: V, size: CGSize, dark: Bool) -> NSImage {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Two passes: geometry readers settle on the second layout.
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return NSImage(size: size)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
