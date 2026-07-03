import Cocoa
import Quartz
import MarkdownEngine
import MarkdownRender

/// Quick Look preview: renders a `.md` file in Vireo's hidden-syntax style,
/// read-only, reusing the exact same parse → render → layout pipeline as the app.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var scrollView: NSScrollView!
    private let imageLoader = ImageLoader()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let scroll = NSScrollView(frame: root.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        root.addSubview(scroll)
        self.scrollView = scroll
        self.view = root
    }

    // `QLPreviewingController` is not actor-isolated in the SDK; Quick Look calls
    // this on the main thread, so we implement it `nonisolated` and assume the
    // main actor to touch the (main-actor) view hierarchy.
    nonisolated func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let base = url.deletingLastPathComponent()
            MainActor.assumeIsolated { render(source: source, baseURL: base) }
            handler(nil)
        } catch {
            handler(error)
        }
    }

    private func render(source: String, baseURL: URL) {
        let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let theme = Theme(zoom: 1.0)
        let parsed = MarkdownParser().parse(source)
        let renderer = MarkdownRenderer(theme: theme, baseURL: baseURL,
                                        imageLoader: imageLoader, isDark: isDark)
        let attributed = renderer.render(source: source, parsed: parsed)

        let storage = NSTextStorage(attributedString: attributed)
        let layout = MarkdownLayoutManager()
        layout.markerColor = theme.secondaryColor
        layout.bulletFont = theme.bodyFont
        layout.tables = parsed.tables
        layout.tableRowHeight = theme.tableRowHeight
        layout.tableFont = theme.tableFont
        layout.tableHeaderFont = theme.tableHeaderFont
        layout.imageProvider = { [weak self] src in
            self?.imageLoader.image(forSource: src, baseURL: baseURL)
        }
        storage.addLayoutManager(layout)

        let container = NSTextContainer(size: NSSize(width: scrollView.contentSize.width,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 8
        layout.addTextContainer(container)

        let textView = NSTextView(frame: scrollView.bounds, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // Lift the default (frame-sized) maxSize or the preview can't scroll.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
    }
}
