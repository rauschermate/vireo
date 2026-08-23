import AppKit
import MarkdownEngine

public struct TableCellID: Hashable, Sendable {
    public var tableAnchor: Int
    public var row: Int
    public var column: Int

    public init(tableAnchor: Int, row: Int, column: Int) {
        self.tableAnchor = tableAnchor
        self.row = row
        self.column = column
    }
}

public struct TableCellGeometry: Sendable {
    public var id: TableCellID
    public var rect: NSRect
    public var isHeader: Bool
    public var alignment: TableAlignment

    public init(id: TableCellID, rect: NSRect, isHeader: Bool,
                alignment: TableAlignment) {
        self.id = id
        self.rect = rect
        self.isHeader = isHeader
        self.alignment = alignment
    }
}

public struct TableScrollGeometry: Sendable {
    public var tableAnchor: Int
    /// The visible table window, in text-container coordinates.
    public var viewportRect: NSRect
    public var contentWidth: CGFloat
    public var offset: CGFloat

    public var maxOffset: CGFloat { max(0, contentWidth - viewportRect.width) }
    public var isOverflowing: Bool { maxOffset > 0.5 }

    public init(tableAnchor: Int, viewportRect: NSRect,
                contentWidth: CGFloat, offset: CGFloat) {
        self.tableAnchor = tableAnchor
        self.viewportRect = viewportRect
        self.contentWidth = contentWidth
        self.offset = offset
    }
}

private struct PreparedTableCell {
    let id: TableCellID
    let attributedText: NSAttributedString
    let isHeader: Bool
    let alignment: TableAlignment
    let contentHeight: CGFloat
}

private struct CachedTableLayout {
    let columnWidths: [CGFloat]
    let columnOffsets: [CGFloat]
    let cells: [PreparedTableCell]
    let totalWidth: CGFloat
}

/// TextKit-1 layout manager that realises the hidden-syntax look:
///  • syntax-marker glyphs (`.vireoMarker`) are turned into null glyphs — present
///    in the backing store, zero-width and invisible on screen;
///  • list bullets / numbers, task checkboxes and inline images (which are *not*
///    literal glyphs in the source) are drawn on top.
///
/// The backing text storage is never mutated, so `textStorage.string` stays
/// byte-identical to the markdown on disk.
///
/// Not `@MainActor`-annotated: `NSLayoutManager`/its delegate protocol are not
/// actor-isolated in the SDK, and all layout/drawing happens on the main thread
/// at runtime.
public final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    public var markerColor: NSColor = .secondaryLabelColor
    public var bulletFont: NSFont = .systemFont(ofSize: 16)
    public var imageProvider: ((String) -> NSImage?)?
    public var imageMaxWidth: CGFloat = 640
    /// The rendered image currently selected by the editor, if any.
    /// Selection is visual only; the Markdown source remains hidden.
    public var selectedImageAnchor: Int?
    private(set) var codeBlockRects: [Int: NSRect] = [:]
    private(set) var quoteBarRects: [Int: NSRect] = [:]
    private(set) var thematicRuleRects: [Int: NSRect] = [:]

    // Table drawing config (set on each restyle).
    public var tables: [TableInfo] = [] {
        didSet {
            let anchors = Set(tables.map(\.anchor))
            tableHorizontalOffsets = tableHorizontalOffsets.filter { anchors.contains($0.key) }
            tablesByAnchor = Dictionary(uniqueKeysWithValues: tables.map { ($0.anchor, $0) })
            if oldValue != tables { invalidateTableRenderCache() }
        }
    }
    public var tableRowHeight: CGFloat = 40 {
        didSet { if oldValue != tableRowHeight { invalidateTableRenderCache() } }
    }
    public var tableScrollerGutter: CGFloat = 0 {
        didSet { if oldValue != tableScrollerGutter { invalidateTableRenderCache() } }
    }
    public var tableFont: NSFont = .systemFont(ofSize: 15) {
        didSet { if oldValue != tableFont { invalidateTableRenderCache() } }
    }
    public var tableHeaderFont: NSFont = .systemFont(ofSize: 15, weight: .semibold) {
        didSet { if oldValue != tableHeaderFont { invalidateTableRenderCache() } }
    }
    /// Editor surfaces enable this; static snapshots and Quick Look retain the
    /// compact fit-to-column rendering used before rich table interaction.
    public var tableHorizontalScrollingEnabled = false {
        didSet {
            if oldValue != tableHorizontalScrollingEnabled {
                invalidateTableRenderCache()
            }
        }
    }
    /// Cell frames from the current draw pass, in text-container coordinates.
    /// Keeping these independent of `drawGlyphs(... at:)` is essential because
    /// AppKit can translate that origin for partial/scrolled drawing passes.
    public private(set) var tableCellGeometries: [TableCellID: TableCellGeometry] = [:]
    /// Table bounds in text-container coordinates, keyed by source anchor.
    public private(set) var tableRects: [Int: NSRect] = [:]
    public private(set) var tableScrollGeometries: [Int: TableScrollGeometry] = [:]
    private var tableHorizontalOffsets: [Int: CGFloat] = [:]
    private(set) var tableRenderCacheBuildCount = 0
    private var tablesByAnchor: [Int: TableInfo] = [:]
    private var tableRenderCache: [Int: CachedTableLayout] = [:]
    private var cachedTableWidth: CGFloat?

    public func beginTableGeometryPass() {
        tableCellGeometries.removeAll(keepingCapacity: true)
        tableRects.removeAll(keepingCapacity: true)
        tableScrollGeometries.removeAll(keepingCapacity: true)
        chevronRects.removeAll(keepingCapacity: true)
        dotsRects.removeAll(keepingCapacity: true)
        collapseHoverRects.removeAll(keepingCapacity: true)
        checkboxRects.removeAll(keepingCapacity: true)
        imageRects.removeAll(keepingCapacity: true)
        sourceBlockRects.removeAll(keepingCapacity: true)
    }

    public func tableCell(at point: NSPoint) -> TableCellGeometry? {
        tableCellGeometries.values.first { $0.rect.contains(point) }
    }

    public func geometry(for id: TableCellID) -> TableCellGeometry? {
        tableCellGeometries[id]
    }

    public func tableScrollGeometry(for anchor: Int) -> TableScrollGeometry? {
        tableScrollGeometries[anchor]
    }

    public func overflowingTableAnchor(at point: NSPoint) -> Int? {
        tableScrollGeometries.values.first {
            $0.isOverflowing && $0.viewportRect.contains(point)
        }?.tableAnchor
    }

    /// Positive offsets reveal content farther to the right. Cell hit frames
    /// move immediately so interaction remains correct before the redraw lands.
    @discardableResult
    public func setTableHorizontalOffset(_ proposed: CGFloat, for anchor: Int) -> Bool {
        guard var scroll = tableScrollGeometries[anchor], scroll.isOverflowing else {
            return false
        }
        let next = min(max(0, proposed), scroll.maxOffset)
        guard abs(next - scroll.offset) > 0.25 else { return false }
        let shift = scroll.offset - next
        scroll.offset = next
        tableScrollGeometries[anchor] = scroll
        tableHorizontalOffsets[anchor] = next
        let ids = tableCellGeometries.keys.filter { $0.tableAnchor == anchor }
        for id in ids {
            guard var geometry = tableCellGeometries[id] else { continue }
            geometry.rect = geometry.rect.offsetBy(dx: shift, dy: 0)
            tableCellGeometries[id] = geometry
        }
        return true
    }

    /// Bring a keyboard-navigated cell fully into the table viewport whenever
    /// its width allows it; oversized cells align to their leading edge.
    @discardableResult
    public func revealTableCell(_ id: TableCellID, padding: CGFloat = 8) -> Bool {
        guard let cell = tableCellGeometries[id],
              let scroll = tableScrollGeometries[id.tableAnchor],
              scroll.isOverflowing else { return false }
        let visibleMin = scroll.viewportRect.minX + padding
        let visibleMax = scroll.viewportRect.maxX - padding
        var proposed = scroll.offset
        if cell.rect.width >= visibleMax - visibleMin {
            proposed += cell.rect.minX - visibleMin
        } else if cell.rect.minX < visibleMin {
            proposed -= visibleMin - cell.rect.minX
        } else if cell.rect.maxX > visibleMax {
            proposed += cell.rect.maxX - visibleMax
        }
        return setTableHorizontalOffset(proposed, for: id.tableAnchor)
    }

    // List/heading collapse and hover state (set on each restyle / mouse move).
    public var listMarkers: [ListMarker] = [] {
        didSet { listGuideIndexNeedsRebuild = true }
    }
    public var taskMarks: [TaskMark] = [] {
        didSet { listGuideIndexNeedsRebuild = true }
    }
    public var headingMarks: [HeadingMark] = []
    public var collapsedAnchors: Set<Int> = []
    public var hoveredAnchor: Int?
    /// Source region whose markers the editor currently reveals (the block
    /// that holds the caret). Constructs inside it show raw syntax, so their
    /// drawn stand-ins adapt: bullets and checkboxes yield to the raw text,
    /// and fold chevrons pin to the line's resting position instead of the
    /// anchor glyph — which shifts right when the markers gain width.
    public var syntaxRevealRange: NSRange?
    private var listGuideIndex = ListGuideIndex(listMarkers: [], tasks: [])
    private var listGuideIndexNeedsRebuild = false

    /// Hit-test rects recorded during drawing (text-view coordinates):
    /// chevron toggles and collapsed-`…` expanders, keyed by item anchor.
    public private(set) var chevronRects: [Int: NSRect] = [:]
    public private(set) var dotsRects: [Int: NSRect] = [:]
    /// Full collapsible line bounds in text-view coordinates. These make
    /// heading disclosure hover reliable even when the pointer approaches
    /// through the leading margin rather than directly over a glyph.
    public private(set) var collapseHoverRects: [Int: NSRect] = [:]
    public private(set) var checkboxRects: [Int: NSRect] = [:]
    /// Rendered image hit targets in text-container coordinates, keyed by source
    /// anchor. Keeping these independent of a particular drawing pass matters:
    /// AppKit may translate `origin` while drawing a scrolled dirty region.
    public private(set) var imageRects: [Int: NSRect] = [:]
    /// Metadata / unsupported-HTML placeholder bounds in text-container
    /// coordinates, keyed by their source anchor.
    public private(set) var sourceBlockRects: [Int: NSRect] = [:]

    public override init() {
        super.init()
        // Requesting a distant viewport in a large document must not first
        // typeset every preceding character. This also keeps TextKit's idle
        // background layout from monopolising the main thread after open.
        allowsNonContiguousLayout = true
        self.delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowsNonContiguousLayout = true
        self.delegate = self
    }

    private func invalidateTableRenderCache() {
        tableRenderCache.removeAll(keepingCapacity: true)
        cachedTableWidth = nil
    }

    public override func processEditing(for textStorage: NSTextStorage,
                                        edited editMask: NSTextStorageEditActions,
                                        range newCharRange: NSRange,
                                        changeInLength delta: Int,
                                        invalidatedRange invalidatedCharRange: NSRange) {
        if editMask.contains(.editedCharacters) {
            invalidateTableRenderCache()
        }
        super.processEditing(for: textStorage, edited: editMask,
                             range: newCharRange, changeInLength: delta,
                             invalidatedRange: invalidatedCharRange)
    }

    // MARK: Hide markers by emitting null glyphs

    public func layoutManager(_ layoutManager: NSLayoutManager,
                              shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                              properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                              characterIndexes charIndexes: UnsafePointer<Int>,
                              font: NSFont,
                              forGlyphRange glyphRange: NSRange) -> Int {
        let signpost = VireoPerformanceTrace.begin("Glyph Generation")
        defer { VireoPerformanceTrace.end("Glyph Generation", signpost) }
        guard let storage = textStorage else { return 0 }
        let count = glyphRange.length
        var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: count)
        var newGlyphs: [CGGlyph]?
        var changed = false
        let ns = storage.string as NSString
        for i in 0..<count {
            let charIndex = charIndexes[i]
            guard charIndex < storage.length else { newProps[i] = props[i]; continue }
            if storage.attribute(.vireoCollapsed, at: charIndex, effectiveRange: nil) != nil {
                // Collapsed ranges keep their newlines (each hidden line stays
                // its own ~zero-height fragment — nulling them would merge a
                // whole folded section into one line fragment, and the TextKit-1
                // typesetter breaks past ~16K glyphs on a line).
                if ns.character(at: charIndex) == 0x0A {
                    newProps[i] = props[i]
                } else {
                    newProps[i] = .null
                    changed = true
                }
            } else if storage.attribute(.vireoSourceBlock, at: charIndex, effectiveRange: nil) != nil
                        || storage.attribute(.vireoInlineHTML, at: charIndex, effectiveRange: nil) != nil {
                // Keep one transparent glyph as geometry for the native
                // replacement that drawGlyphs paints at this source position.
                newProps[i] = props[i]
            } else if storage.attribute(.vireoMetadata, at: charIndex, effectiveRange: nil) != nil {
                // As with collapsed content, retain line endings so TextKit
                // never sees one enormous logical line. Paragraph styles make
                // all but the placeholder's first line effectively zero high.
                if ns.character(at: charIndex) == 0x0A {
                    newProps[i] = props[i]
                } else {
                    newProps[i] = .null
                    changed = true
                }
            } else if storage.attribute(.vireoCodeBlock, at: charIndex,
                                        effectiveRange: nil) != nil,
                      storage.attribute(.vireoMarker, at: charIndex,
                                        effectiveRange: nil) != nil,
                      ns.character(at: charIndex) == 0x0A {
                // Keep fenced-code line endings as transparent geometry. Their
                // compact paragraph style supplies symmetric surface padding
                // while every visible fence character remains null-hidden.
                newProps[i] = props[i]
            } else if storage.attribute(.vireoMarker, at: charIndex, effectiveRange: nil) != nil {
                newProps[i] = .null
                changed = true
            } else if storage.attribute(.vireoArrow, at: charIndex, effectiveRange: nil) != nil {
                // Substitute the `-` of a prose `->` with a real → glyph.
                var ch: UniChar = 0x2192 // →
                var arrow: CGGlyph = 0
                if CTFontGetGlyphsForCharacters(font as CTFont, &ch, &arrow, 1), arrow != 0 {
                    if newGlyphs == nil {
                        newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
                    }
                    newGlyphs?[i] = arrow
                    changed = true
                }
                newProps[i] = props[i]
            } else {
                newProps[i] = props[i]
            }
        }
        guard changed else { return 0 }
        let glyphBase = newGlyphs ?? Array(UnsafeBufferPointer(start: glyphs, count: count))
        glyphBase.withUnsafeBufferPointer { glyphBuf in
            newProps.withUnsafeBufferPointer { propBuf in
                self.setGlyphs(glyphBuf.baseAddress!, properties: propBuf.baseAddress!,
                               characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
            }
        }
        return count
    }

    // MARK: Draw bullets / checkboxes / images

    public override func drawBackground(forGlyphRange glyphsToShow: NSRange,
                                        at origin: NSPoint) {
        codeBlockRects.removeAll(keepingCapacity: true)
        quoteBarRects.removeAll(keepingCapacity: true)
        thematicRuleRects.removeAll(keepingCapacity: true)
        drawBlockDecorations(forGlyphRange: glyphsToShow, origin: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Draw block-level surfaces behind glyph backgrounds and selection. Work
    /// is bounded to the glyph range TextKit asked to paint, so a long code or
    /// quote block does not force layout of its off-screen remainder.
    private func drawBlockDecorations(forGlyphRange glyphsToShow: NSRange,
                                      origin: NSPoint) {
        guard let storage = textStorage, !textContainers.isEmpty else { return }
        let visibleCharacters = characterRange(forGlyphRange: glyphsToShow,
                                               actualGlyphRange: nil)
        let full = NSRange(location: 0, length: storage.length)

        func decorations(for key: NSAttributedString.Key)
            -> [(range: NSRange, color: NSColor)] {
            var found: [(NSRange, NSColor)] = []
            var seen: Set<Int> = []
            storage.enumerateAttribute(key, in: visibleCharacters) { value, range, _ in
                guard value != nil, range.location < storage.length else { return }
                var effective = NSRange()
                guard let color = storage.attribute(
                    key, at: range.location, longestEffectiveRange: &effective, in: full
                ) as? NSColor,
                seen.insert(effective.location).inserted,
                storage.attribute(.vireoCollapsed, at: effective.location,
                                  effectiveRange: nil) == nil else { return }
                found.append((effective, color))
            }
            return found
        }

        for decoration in decorations(for: .vireoCodeBlock) {
            guard let bounds = decorationBounds(
                for: decoration.range, visibleCharacters: visibleCharacters
            ) else { continue }
            let rect = bounds.offsetBy(dx: origin.x, dy: origin.y)
                .insetBy(dx: 4, dy: 1)
            codeBlockRects[decoration.range.location] = rect
            let surface = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            decoration.color.setFill()
            surface.fill()
            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            surface.lineWidth = 0.5
            surface.stroke()
        }

        for decoration in decorations(for: .vireoBlockQuote) {
            guard let bounds = decorationBounds(
                for: decoration.range, visibleCharacters: visibleCharacters
            ) else { continue }
            let rect = NSRect(x: origin.x + bounds.minX + 5,
                              y: origin.y + bounds.minY + 2,
                              width: 3, height: max(1, bounds.height - 4))
            quoteBarRects[decoration.range.location] = rect
            decoration.color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }

        for decoration in decorations(for: .vireoThematicBreak) {
            guard let bounds = decorationBounds(
                for: decoration.range, visibleCharacters: visibleCharacters
            ) else { continue }
            let left = origin.x + bounds.minX + 16
            let right = origin.x + bounds.maxX - 16
            guard right > left else { continue }
            let rule = NSBezierPath()
            rule.lineWidth = 1
            rule.move(to: NSPoint(x: left, y: origin.y + bounds.midY))
            rule.line(to: NSPoint(x: right, y: origin.y + bounds.midY))
            decoration.color.setStroke()
            rule.stroke()
            thematicRuleRects[decoration.range.location] = NSRect(
                x: left, y: origin.y + bounds.midY - 0.5,
                width: right - left, height: 1
            )
        }
    }

    private func decorationBounds(for range: NSRange,
                                  visibleCharacters: NSRange) -> NSRect? {
        let visible = NSIntersectionRange(range, visibleCharacters)
        guard visible.length > 0 else { return nil }
        let glyphs = glyphRange(forCharacterRange: visible,
                                actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var bounds: NSRect?
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
            guard NSIntersectionRange(glyphs, lineGlyphs).length > 0 else { return }
            bounds = bounds.map { NSUnionRect($0, fragment) } ?? fragment
        }
        return bounds
    }

    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let signpost = VireoPerformanceTrace.begin("Visible Draw")
        defer { VireoPerformanceTrace.end("Visible Draw", signpost) }
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        func isCollapsedAway(_ index: Int) -> Bool {
            index < storage.length
                && storage.attribute(.vireoCollapsed, at: index, effectiveRange: nil) != nil
        }

        drawListGuides(visibleCharRange: charRange,
                       visibleGlyphRange: glyphsToShow, origin: origin)

        storage.enumerateAttribute(.vireoBullet, in: charRange) { value, range, _ in
            guard let s = value as? String, !isCollapsedAway(range.location) else { return }
            let anchor = range.location
            let collapsed = collapsedAnchors.contains(anchor)
            let color: NSColor = collapsed ? .controlAccentColor : markerColor
            if collapsed { drawCollapseHalo(atCharIndex: anchor, markerText: s, origin: origin) }
            // A revealed line shows its raw `- ` — a drawn bullet next to it
            // would double the marker.
            if !isSyntaxRevealed(at: anchor) {
                drawLeftMarker(s, atCharIndex: anchor, origin: origin, color: color)
            }
            drawListAdornments(anchor: anchor, markerText: s, origin: origin)
        }
        storage.enumerateAttribute(.vireoCheckbox, in: charRange) { value, range, _ in
            guard let n = value as? NSNumber, !isCollapsedAway(range.location) else { return }
            // As with bullets: the revealed line shows its raw `- [ ]`, so the
            // drawn checkbox (and its click target) steps aside.
            if !isSyntaxRevealed(at: range.location) {
                drawCheckbox(checked: n.boolValue, atCharIndex: range.location, origin: origin)
            }
            drawListAdornments(anchor: range.location, markerText: nil, origin: origin)
        }
        storage.enumerateAttribute(.vireoHeading, in: charRange) { value, range, _ in
            guard value is NSNumber, !isCollapsedAway(range.location) else { return }
            drawHeadingAdornments(anchor: range.location, origin: origin, storage: storage)
        }
        storage.enumerateAttribute(.vireoImage, in: charRange) { value, range, _ in
            guard let src = value as? String, !isCollapsedAway(range.location) else { return }
            if let img = imageProvider?(src) {
                drawImage(img, atCharIndex: range.location, origin: origin)
            } else {
                let alt = storage.attribute(.vireoImageAlt, at: range.location,
                                            effectiveRange: nil) as? String ?? ""
                drawImageFallback(alt: alt, atCharIndex: range.location, origin: origin)
            }
        }
        storage.enumerateAttribute(.vireoTable, in: charRange) { value, range, _ in
            guard let n = value as? NSNumber,
                  let info = tablesByAnchor[n.intValue],
                  !isCollapsedAway(range.location) else { return }
            drawTable(info, atCharIndex: range.location, origin: origin, storage: storage)
        }
        storage.enumerateAttribute(.vireoSourceBlock, in: charRange) { value, range, _ in
            guard let label = value as? String, !isCollapsedAway(range.location) else { return }
            drawSourceBlock(label: label, atCharIndex: range.location, origin: origin)
        }
        storage.enumerateAttribute(.vireoInlineHTML, in: charRange) { value, range, _ in
            guard let kind = value as? String, !isCollapsedAway(range.location) else { return }
            drawInlineHTML(kind: kind, atCharIndex: range.location, origin: origin)
        }
    }

    // MARK: Source-only placeholders

    private func drawSourceBlock(label: String, atCharIndex charIndex: Int, origin: NSPoint) {
        sourceBlockRects[charIndex] = nil
        guard let storage = textStorage, charIndex < storage.length else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = location(forGlyphAt: glyph)
        let font = NSFont.systemFont(ofSize: max(11, bulletFont.pointSize * 0.76), weight: .medium)
        let iconName = label.contains("not rendered")
            ? "chevron.left.forwardslash.chevron.right" : "info.circle"
        let iconSize: CGFloat = 13
        let gap: CGFloat = 6
        let horizontal: CGFloat = 9
        let height: CGFloat = 24
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let width = horizontal * 2 + iconSize + gap + textSize.width
        let containerRect = NSRect(x: line.minX + location.x,
                                   y: line.minY + (line.height - height) / 2,
                                   width: width, height: height)
        sourceBlockRects[charIndex] = containerRect
        let rect = containerRect.offsetBy(dx: origin.x, dy: origin.y)

        NSColor.controlBackgroundColor.withAlphaComponent(0.72).setFill()
        let pill = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        pill.fill()
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        pill.lineWidth = 0.75
        pill.stroke()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        if let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            let iconRect = NSRect(x: rect.minX + horizontal,
                                  y: rect.midY - iconSize / 2,
                                  width: iconSize, height: iconSize)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver,
                      fraction: 0.82, respectFlipped: true, hints: nil)
        }
        (label as NSString).draw(at: NSPoint(x: rect.minX + horizontal + iconSize + gap,
                                             y: rect.midY - textSize.height / 2),
                                 withAttributes: attrs)
    }

    private func drawInlineHTML(kind: String, atCharIndex charIndex: Int, origin: NSPoint) {
        guard let storage = textStorage, charIndex < storage.length else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = location(forGlyphAt: glyph)
        let x = origin.x + line.minX + location.x

        if kind == "line-break" {
            let font = NSFont.systemFont(ofSize: max(11, bulletFont.pointSize * 0.78), weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let symbol = "↵" as NSString
            let baseline = origin.y + line.minY + location.y
            symbol.draw(at: NSPoint(x: x, y: baseline - font.ascender), withAttributes: attrs)
            return
        }

        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let symbol = "</>" as NSString
        let size = symbol.size(withAttributes: attrs)
        let height: CGFloat = 16
        let rect = NSRect(x: x, y: origin.y + line.midY - height / 2,
                          width: size.width + 7, height: height)
        NSColor.controlBackgroundColor.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        border.lineWidth = 0.75
        border.stroke()
        symbol.draw(at: NSPoint(x: rect.midX - size.width / 2,
                                y: rect.midY - size.height / 2),
                    withAttributes: attrs)
    }

    // MARK: Text-only selection highlight

    /// Persistent buffer backing our `rectArray` override. `NSLayoutManager`'s
    /// contract is that the returned pointer stays valid until the next call, so
    /// we own storage that lives across calls and grows as needed.
    private var selectionRects: UnsafeMutablePointer<NSRect>?
    private var selectionRectCapacity = 0

    deinit { selectionRects?.deallocate() }

    /// Trim the selection highlight to the text itself.
    ///
    /// This is the primitive `NSTextView` calls to compute selection rectangles.
    /// The default merges every line wholly inside the selection into a *single*
    /// block rect at full container width, so a multi-line selection reads as one
    /// solid slab reaching the right margin. More refined editors (Medium,
    /// Notion, VS Code) highlight only the glyphs. We can't just trim that merged
    /// slab — it spans many lines of differing width — so we rebuild the rects
    /// one line fragment at a time, each clamped to the selected glyphs' actual
    /// horizontal extent: the line's *used* rect for a fully-covered line, or the
    /// caret x of the selection edge on a partially-covered first/last line.
    /// Empty lines collapse to nothing. Fixing the geometry at this single source
    /// makes it hold across every drawing path `NSTextView` uses.
    public override func rectArray(forCharacterRange charRange: NSRange,
                                   withinSelectedCharacterRange selCharRange: NSRange,
                                   in container: NSTextContainer,
                                   rectCount: UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<NSRect>? {
        guard charRange.length > 0, numberOfGlyphs > 0 else {
            return super.rectArray(forCharacterRange: charRange,
                                   withinSelectedCharacterRange: selCharRange,
                                   in: container, rectCount: rectCount)
        }
        let selGlyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var out: [NSRect] = []
        enumerateLineFragments(forGlyphRange: selGlyphs) { fragmentRect, usedRect, _, lineGlyphs, _ in
            let onLine = NSIntersectionRange(selGlyphs, lineGlyphs)
            guard onLine.length > 0 else { return }

            // Left edge: the selection's start glyph if it begins mid-line,
            // otherwise the text's own left edge (used rect).
            var left = usedRect.minX
            if onLine.location > lineGlyphs.location, onLine.location < self.numberOfGlyphs {
                left = fragmentRect.minX + self.location(forGlyphAt: onLine.location).x
            }
            // Right edge: the selection's end glyph if it stops mid-line,
            // otherwise the text's own right edge (used rect) — never the margin.
            var right = usedRect.maxX
            let end = onLine.location + onLine.length
            if end < lineGlyphs.location + lineGlyphs.length, end < self.numberOfGlyphs {
                right = fragmentRect.minX + self.location(forGlyphAt: end).x
            }
            left = max(left, usedRect.minX)
            right = min(right, usedRect.maxX)
            if right > left {
                out.append(NSRect(x: left, y: fragmentRect.minY,
                                  width: right - left, height: fragmentRect.height))
            }
        }
        guard !out.isEmpty else {
            rectCount.pointee = 0
            return super.rectArray(forCharacterRange: charRange,
                                   withinSelectedCharacterRange: selCharRange,
                                   in: container, rectCount: rectCount)
        }
        if selectionRectCapacity < out.count {
            selectionRects?.deallocate()
            selectionRects = .allocate(capacity: out.count)
            selectionRectCapacity = out.count
        }
        for (i, r) in out.enumerated() { selectionRects![i] = r }
        rectCount.pointee = out.count
        return selectionRects
    }

    // MARK: List collapse UI (chevrons, halo, …, guides)

    private func subtree(forAnchor anchor: Int) -> NSRange? {
        if let m = listMarkers.first(where: { $0.anchor == anchor }) { return m.subtreeRange }
        if let t = taskMarks.first(where: { $0.anchor == anchor }) { return t.subtreeRange }
        if let h = headingMarks.first(where: { $0.anchor == anchor }) { return h.subtreeRange }
        return nil
    }

    func isSyntaxRevealed(at anchor: Int) -> Bool {
        guard let reveal = syntaxRevealRange else { return false }
        return NSLocationInRange(anchor, reveal)
    }

    /// The anchor glyph's resting x — where it sits while its leading markers
    /// are hidden: line-fragment padding + the paragraph's indent + the
    /// line's leading whitespace, which stays visible in both states.
    /// Reads the style at the paragraph's first character (the one TextKit
    /// honors) and uses `headIndent`, not `firstLineHeadIndent` — the two are
    /// equal at rest, but the editor pulls the first-line indent back on
    /// revealed list lines to hang the raw marker in the gutter. Keeps fold
    /// controls and guides still while the revealed marker occupies it.
    private func restingTextX(anchor: Int, lineRect: NSRect) -> CGFloat {
        let padding = textContainers.first?.lineFragmentPadding ?? 0
        guard let storage = textStorage, storage.length > 0 else {
            return lineRect.minX + padding
        }
        let ns = storage.string as NSString
        let location = min(max(0, anchor), storage.length - 1)
        let line = ns.paragraphRange(for: NSRange(location: location, length: 0))
        let style = storage.attribute(.paragraphStyle, at: line.location,
                                      effectiveRange: nil) as? NSParagraphStyle

        var end = line.location
        let limit = min(line.upperBound, storage.length)
        while end < limit,
              ns.character(at: end) == 0x20 || ns.character(at: end) == 0x09 {
            end += 1
        }
        var leadingWidth: CGFloat = 0
        if end > line.location {
            let leading = ns.substring(with: NSRange(location: line.location,
                                                     length: end - line.location))
            let font = storage.attribute(.font, at: line.location,
                                         effectiveRange: nil) as? NSFont ?? bulletFont
            leadingWidth = (leading as NSString)
                .size(withAttributes: [.font: font]).width
        }
        return lineRect.minX + padding + (style?.headIndent ?? 0) + leadingWidth
    }

    func markerGeometry(anchor: Int, markerText: String?) -> (lineRect: NSRect, baseline: CGFloat, textX: CGFloat, markerWidth: CGFloat)? {
        guard anchor < numberOfGlyphs else { return nil }
        let glyph = glyphIndexForCharacter(at: anchor)
        guard glyph < numberOfGlyphs else { return nil }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let loc = location(forGlyphAt: glyph)
        let width: CGFloat
        if let markerText {
            width = (markerText as NSString)
                .size(withAttributes: [.font: bulletFont]).width
        } else {
            width = max(12, min(16, bulletFont.pointSize * 0.9)) // checkbox
        }
        let textX = isSyntaxRevealed(at: anchor)
            ? restingTextX(anchor: anchor, lineRect: lineRect)
            : lineRect.minX + loc.x
        return (lineRect, lineRect.minY + loc.y, textX, width)
    }

    /// Chevron (hover / collapsed) and the collapsed `…` expander.
    private func drawListAdornments(anchor: Int, markerText: String?, origin: NSPoint) {
        let collapsed = collapsedAnchors.contains(anchor)
        let hovered = hoveredAnchor == anchor
        chevronRects[anchor] = nil
        dotsRects[anchor] = nil
        collapseHoverRects[anchor] = nil
        guard subtree(forAnchor: anchor) != nil,
              let geo = markerGeometry(anchor: anchor, markerText: markerText) else { return }
        collapseHoverRects[anchor] = NSRect(
            x: origin.x + geo.lineRect.minX - 48,
            y: origin.y + geo.lineRect.minY,
            width: geo.lineRect.width + 48,
            height: geo.lineRect.height
        )

        // A parent task has both a disclosure control and a checkbox. Keep
        // their 40-point targets adjacent rather than overlapping so either
        // action remains unambiguous. Ordinary list markers have no second
        // control and retain their more compact visual placement.
        let centerX: CGFloat
        if markerText == nil {
            let checkboxCenterX = origin.x + geo.textX - geo.markerWidth / 2 - 6
            centerX = checkboxCenterX - 40
        } else {
            centerX = origin.x + geo.textX - geo.markerWidth - 5 - 12
        }
        let center = NSPoint(x: centerX,
                             y: origin.y + geo.baseline - bulletFont.capHeight / 2)
        chevronRects[anchor] = minimumHitRect(centeredAt: center)
        guard collapsed || hovered else { return }
        drawDisclosureChevron(at: center, collapsed: collapsed)
        // `…` after the collapsed line's text; click to expand.
        if collapsed, anchor < numberOfGlyphs {
            let glyph = glyphIndexForCharacter(at: anchor)
            let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let dots = "…" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: bulletFont,
                                                        .foregroundColor: NSColor.tertiaryLabelColor]
            let size = dots.size(withAttributes: attrs)
            let at = NSPoint(x: origin.x + used.maxX + 8,
                             y: origin.y + geo.baseline - bulletFont.ascender)
            dots.draw(at: at, withAttributes: attrs)
            let visual = NSRect(x: at.x - 4, y: at.y,
                                width: size.width + 12, height: size.height)
            dotsRects[anchor] = minimumHitRect(containing: visual)
        }
    }

    /// Heading fold chevron (hover / collapsed) and the collapsed `…` expander —
    /// same interaction as list items, sized to the heading's own font.
    private func drawHeadingAdornments(anchor: Int, origin: NSPoint, storage: NSTextStorage) {
        let collapsed = collapsedAnchors.contains(anchor)
        chevronRects[anchor] = nil
        dotsRects[anchor] = nil
        collapseHoverRects[anchor] = nil
        guard subtree(forAnchor: anchor) != nil,
              anchor < numberOfGlyphs else { return }
        let glyph = glyphIndexForCharacter(at: anchor)
        guard glyph < numberOfGlyphs else { return }
        let font = (storage.attribute(.font, at: anchor, effectiveRange: nil) as? NSFont) ?? bulletFont
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let loc = location(forGlyphAt: glyph)
        let baseline = origin.y + lineRect.minY + loc.y
        // While the heading's `#` prefix is revealed, keep the chevron at the
        // line's resting position — otherwise it rides right with the anchor
        // glyph and lands on top of the hashes.
        let textX = isSyntaxRevealed(at: anchor)
            ? origin.x + restingTextX(anchor: anchor, lineRect: lineRect)
            : origin.x + lineRect.minX + loc.x
        collapseHoverRects[anchor] = NSRect(
            x: origin.x + lineRect.minX - 48,
            y: origin.y + lineRect.minY,
            width: lineRect.width + 48,
            height: lineRect.height
        )

        // Use the identical icon, spacing, color and state treatment as an
        // unmarked collapsible list row. Headings differ only in the font used
        // to find their vertical center.
        let center = NSPoint(x: textX - 17, y: baseline - font.capHeight / 2)
        chevronRects[anchor] = minimumHitRect(centeredAt: center)
        guard collapsed else { return }

        // `…` after the collapsed heading's text; click to expand.
        let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let dots = "…" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font,
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
        let size = dots.size(withAttributes: attrs)
        let at = NSPoint(x: origin.x + used.maxX + 8, y: baseline - font.ascender)
        dots.draw(at: at, withAttributes: attrs)
        let visual = NSRect(x: at.x - 4, y: at.y,
                            width: size.width + 12, height: size.height)
        dotsRects[anchor] = minimumHitRect(containing: visual)
    }

    /// Paint heading disclosures after TextKit finishes drawing glyphs. A
    /// heading icon lives to the left of its first glyph, so drawing it from
    /// `drawGlyphs` can be clipped even though its hit target is valid. List
    /// disclosures remain inside their marker runs and use the same renderer
    /// directly from the glyph pass.
    public func drawHeadingDisclosureOverlays(in dirtyRect: NSRect) {
        for heading in headingMarks where heading.subtreeRange != nil {
            let anchor = heading.anchor
            let collapsed = collapsedAnchors.contains(anchor)
            guard collapsed || hoveredAnchor == anchor,
                  let rect = chevronRects[anchor],
                  dirtyRect.intersects(rect) else { continue }
            drawDisclosureChevron(
                at: NSPoint(x: rect.midX, y: rect.midY),
                collapsed: collapsed
            )
        }
    }

    /// One disclosure glyph for lists, tasks and headings. Keeping this in a
    /// single renderer prevents the heading affordance from drifting from the
    /// list interaction as either is polished.
    private func drawDisclosureChevron(at center: NSPoint, collapsed: Bool) {
        let chevron = NSBezierPath()
        chevron.lineWidth = 1.8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        if collapsed { // ›
            chevron.move(to: NSPoint(x: center.x - 2, y: center.y - 4))
            chevron.line(to: NSPoint(x: center.x + 2, y: center.y))
            chevron.line(to: NSPoint(x: center.x - 2, y: center.y + 4))
        } else {       // ⌄
            chevron.move(to: NSPoint(x: center.x - 4, y: center.y - 2))
            chevron.line(to: NSPoint(x: center.x, y: center.y + 2))
            chevron.line(to: NSPoint(x: center.x + 4, y: center.y - 2))
        }
        (collapsed ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setStroke()
        chevron.stroke()
    }

    /// Accent halo behind a collapsed item's bullet.
    private func drawCollapseHalo(atCharIndex anchor: Int, markerText: String, origin: NSPoint) {
        guard let geo = markerGeometry(anchor: anchor, markerText: markerText) else { return }
        let d = max(16, geo.markerWidth + 8)
        let cx = origin.x + geo.textX - 5 - geo.markerWidth / 2
        let cy = origin.y + geo.baseline - bulletFont.capHeight / 2
        let rect = NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    /// Faint vertical guides connecting a parent's marker to its subtree.
    private func drawListGuides(visibleCharRange: NSRange,
                                visibleGlyphRange: NSRange,
                                origin: NSPoint) {
        guard let container = textContainers.first, let storage = textStorage else { return }
        if listGuideIndexNeedsRebuild {
            listGuideIndex = ListGuideIndex(listMarkers: listMarkers, tasks: taskMarks)
            listGuideIndexNeedsRebuild = false
        }
        let viewport = boundingRect(forGlyphRange: visibleGlyphRange, in: container)
        for entry in listGuideIndex.overlapping(visibleCharRange) {
            let visibleSubtree = NSIntersectionRange(entry.subtree, visibleCharRange)
            guard visibleSubtree.length > 0,
                  !collapsedAnchors.contains(entry.anchor),
                  entry.anchor < storage.length,
                  storage.attribute(.vireoCollapsed, at: entry.anchor, effectiveRange: nil) == nil,
                  let geo = markerGeometry(anchor: entry.anchor,
                                           markerText: entry.markerText) else { continue }

            // Geometry is requested only for the visible intersection. Asking
            // TextKit for the complete subtree here used to lay out thousands
            // of off-screen lines during a paint.
            let subGlyphs = glyphRange(forCharacterRange: visibleSubtree,
                                       actualCharacterRange: nil)
            guard subGlyphs.length > 0 else { continue }
            let bounds = boundingRect(forGlyphRange: subGlyphs, in: container)
            guard bounds.height > 1 else { continue }

            let x = origin.x + geo.textX - 5 - geo.markerWidth / 2
            let top = origin.y + max(geo.lineRect.maxY + 2, viewport.minY)
            let bottom = origin.y + min(bounds.maxY - 3, viewport.maxY)
            guard bottom > top else { continue }
            let line = NSBezierPath()
            line.lineWidth = 1
            line.move(to: NSPoint(x: x, y: top))
            line.line(to: NSPoint(x: x, y: bottom))
            NSColor.separatorColor.setStroke()
            line.stroke()
        }
    }

    /// Build the attributed text painted inside a rich table cell. Markdown
    /// delimiters and punctuation escapes are source plumbing, while the
    /// attributes they protect (code, emphasis, links) remain visible.
    func tableDisplayContent(for cell: TableCell, header: Bool,
                             storage: NSTextStorage) -> NSAttributedString {
        let sourceRange = NSIntersectionRange(
            cell.range, NSRange(location: 0, length: storage.length)
        )
        let content = NSMutableAttributedString(
            attributedString: sourceRange.length > 0
                ? storage.attributedSubstring(from: sourceRange)
                : NSAttributedString(string: "")
        )

        var hidden: [NSRange] = []
        if content.length > 0 {
            content.enumerateAttribute(.vireoMarker,
                                       in: NSRange(location: 0, length: content.length)) {
                value, range, _ in
                if value != nil { hidden.append(range) }
            }
            for range in hidden.reversed() { content.deleteCharacters(in: range) }
        }

        // swift-markdown's source range for inline code at a GFM cell boundary
        // can stop immediately before the closing backtick run. The opening
        // delimiter is still tagged above, while the closing run is left just
        // outside the fixed-pitch/background span. Remove that source-only run
        // without touching literal backticks inside code.
        let markedUp = content.string as NSString
        var closingCodeDelimiters: [NSRange] = []
        var delimiterIndex = 0
        while delimiterIndex < markedUp.length {
            guard markedUp.character(at: delimiterIndex) == 0x60 else {
                delimiterIndex += 1
                continue
            }
            var delimiterEnd = delimiterIndex + 1
            while delimiterEnd < markedUp.length,
                  markedUp.character(at: delimiterEnd) == 0x60 {
                delimiterEnd += 1
            }
            let previousIsCode = delimiterIndex > 0
                && content.attribute(.backgroundColor, at: delimiterIndex - 1,
                                     effectiveRange: nil) != nil
            let delimiterIsCode = content.attribute(.backgroundColor,
                                                    at: delimiterIndex,
                                                    effectiveRange: nil) != nil
            if previousIsCode && !delimiterIsCode {
                closingCodeDelimiters.append(
                    NSRange(location: delimiterIndex,
                            length: delimiterEnd - delimiterIndex)
                )
            }
            delimiterIndex = delimiterEnd
        }
        for range in closingCodeDelimiters.reversed() {
            content.deleteCharacters(in: range)
        }

        // CommonMark escapes punctuation with a source-only backslash. This
        // matters most for `\|`, which keeps a literal pipe inside a GFM cell,
        // including inside inline code spans.
        let escapable = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".utf16)
        let visible = content.string as NSString
        var escapeRanges: [NSRange] = []
        var index = 0
        while index + 1 < visible.length {
            if visible.character(at: index) == 0x5C,
               escapable.contains(visible.character(at: index + 1)) {
                escapeRanges.append(NSRange(location: index, length: 1))
                index += 2
            } else {
                index += 1
            }
        }
        for range in escapeRanges.reversed() { content.deleteCharacters(in: range) }

        let full = NSRange(location: 0, length: content.length)
        guard full.length > 0 else { return content }
        content.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        content.enumerateAttribute(.vireoLink, in: full) { value, range, _ in
            if value != nil {
                content.addAttribute(.foregroundColor, value: NSColor.linkColor,
                                     range: range)
            }
        }
        if content.attribute(.font, at: 0, effectiveRange: nil) == nil {
            content.addAttribute(.font, value: header ? tableHeaderFont : tableFont,
                                 range: full)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        switch cell.alignment {
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        default: paragraph.alignment = .left
        }
        content.addAttribute(.paragraphStyle, value: paragraph, range: full)
        return content
    }

    private func drawTable(_ info: TableInfo, atCharIndex charIndex: Int, origin: NSPoint, storage: NSTextStorage) {
        guard charIndex < numberOfGlyphs else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        // Cache all interaction geometry in stable text-container coordinates;
        // add the transient drawing origin only when painting pixels.
        let top = lineRect.minY
        let left = lineRect.minX
        let pad: CGFloat = 10
        let rh = tableRowHeight
        let available = max(72, lineRect.width)
        let cached = cachedTableLayout(info, availableWidth: available,
                                       padding: pad, storage: storage)
        let colW = cached.columnWidths
        let cols = colW.count
        guard cols > 0 else { return }
        let totalW = cached.totalWidth
        let rowCount = info.rows.count
        let rowAreaHeight = CGFloat(rowCount) * rh
        let tableH = rowAreaHeight
            + (tableHorizontalScrollingEnabled ? tableScrollerGutter : 0)
        let maxOffset = tableHorizontalScrollingEnabled ? max(0, totalW - available) : 0
        let offset = min(max(0, tableHorizontalOffsets[info.anchor] ?? 0), maxOffset)
        if maxOffset > 0.5 {
            tableHorizontalOffsets[info.anchor] = offset
        } else {
            tableHorizontalOffsets[info.anchor] = nil
        }

        let xs = cached.columnOffsets.map { left - offset + $0 }
        let right = left - offset + totalW
        let viewport = NSRect(x: left, y: top, width: available, height: tableH)
        tableRects[info.anchor] = viewport
        if tableHorizontalScrollingEnabled {
            tableScrollGeometries[info.anchor] = TableScrollGeometry(
                tableAnchor: info.anchor,
                viewportRect: viewport,
                contentWidth: totalW,
                offset: offset
            )
        }

        // Wide tables scroll inside the reading column; they must never paint
        // over neighboring prose or the surrounding chrome.
        NSGraphicsContext.saveGraphicsState()
        let clip = viewport.offsetBy(dx: origin.x, dy: origin.y)
        NSBezierPath(rect: clip).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Header background.
        NSColor.secondaryLabelColor.withAlphaComponent(0.10)
            .setFill()
        NSRect(x: origin.x + left - offset, y: origin.y + top,
               width: totalW, height: rh).fill()

        // Grid lines.
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for r in 0...rowCount {
            let y = origin.y + top + CGFloat(r) * rh
            grid.move(to: NSPoint(x: origin.x + left - offset, y: y))
            grid.line(to: NSPoint(x: origin.x + right, y: y))
        }
        for i in 0...cols {
            let x = origin.x + (i < xs.count ? xs[i] : right)
            grid.move(to: NSPoint(x: x, y: origin.y + top))
            grid.line(to: NSPoint(x: x, y: origin.y + top + rowAreaHeight))
        }
        NSColor.separatorColor.setStroke()
        grid.stroke()

        // Cell text.
        for cell in cached.cells where cell.id.column < cols {
            let y = top + CGFloat(cell.id.row) * rh
            let cellRect = NSRect(x: xs[cell.id.column], y: y,
                                  width: colW[cell.id.column], height: rh)
            tableCellGeometries[cell.id] = TableCellGeometry(
                id: cell.id, rect: cellRect, isHeader: cell.isHeader,
                alignment: cell.alignment
            )
            guard cell.attributedText.length > 0 else { continue }
            let drawRect = NSRect(x: origin.x + cellRect.minX + pad,
                                  y: origin.y + cellRect.midY - cell.contentHeight / 2,
                                  width: max(1, cellRect.width - pad * 2),
                                  height: cell.contentHeight)
            cell.attributedText.draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                context: nil
            )
        }
    }

    private func cachedTableLayout(_ info: TableInfo, availableWidth: CGFloat,
                                   padding: CGFloat,
                                   storage: NSTextStorage) -> CachedTableLayout {
        if let width = cachedTableWidth, abs(width - availableWidth) > 0.5 {
            tableRenderCache.removeAll(keepingCapacity: true)
        }
        cachedTableWidth = availableWidth
        if let cached = tableRenderCache[info.anchor] { return cached }

        struct CellDraft {
            let id: TableCellID
            let content: NSMutableAttributedString
            let isHeader: Bool
            let alignment: TableAlignment
        }
        let cols = info.columnCount
        guard cols > 0 else {
            return CachedTableLayout(columnWidths: [], columnOffsets: [],
                                     cells: [], totalWidth: 0)
        }
        var drafts: [CellDraft] = []
        var naturalWidths = [CGFloat](repeating: 0, count: cols)
        let maxColumnWidth = max(280, min(480, availableWidth * 0.8))
        for (rowIndex, row) in info.rows.enumerated() {
            for cell in row.cells where cell.column < cols {
                let content = NSMutableAttributedString(
                    attributedString: tableDisplayContent(
                        for: cell, header: row.isHeader, storage: storage
                    )
                )
                naturalWidths[cell.column] = max(
                    naturalWidths[cell.column],
                    min(maxColumnWidth, ceil(content.size().width) + padding * 2)
                )
                drafts.append(CellDraft(
                    id: TableCellID(tableAnchor: info.anchor, row: rowIndex,
                                    column: cell.column),
                    content: content, isHeader: row.isHeader,
                    alignment: cell.alignment
                ))
            }
        }

        // Interactive tables retain readable natural widths and scroll inside
        // the reading column. Static renderers compress very wide tables so
        // snapshots and Quick Look stay bounded without a local scroller.
        let minimum = tableHorizontalScrollingEnabled
            ? 72 : min(72, availableWidth / CGFloat(cols))
        var widths = naturalWidths.map { max(minimum, $0) }
        let desired = widths.reduce(0, +)
        if desired < availableWidth {
            let extra = (availableWidth - desired) / CGFloat(cols)
            widths = widths.map { $0 + extra }
        } else if desired > availableWidth, !tableHorizontalScrollingEnabled {
            let minimumTotal = CGFloat(cols) * minimum
            let scale = (availableWidth - minimumTotal) / max(1, desired - minimumTotal)
            widths = widths.map { minimum + ($0 - minimum) * max(0, scale) }
        }
        var offsets: [CGFloat] = []
        offsets.reserveCapacity(cols)
        var x: CGFloat = 0
        for width in widths { offsets.append(x); x += width }

        let prepared = drafts.map { draft -> PreparedTableCell in
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            switch draft.alignment {
            case .center: paragraph.alignment = .center
            case .right: paragraph.alignment = .right
            default: paragraph.alignment = .left
            }
            let full = NSRange(location: 0, length: draft.content.length)
            if full.length > 0 {
                draft.content.addAttribute(.paragraphStyle, value: paragraph, range: full)
            }
            let contentWidth = max(1, widths[draft.id.column] - padding * 2)
            let measured = draft.content.boundingRect(
                with: NSSize(width: contentWidth, height: tableRowHeight),
                options: [.usesLineFragmentOrigin]
            )
            return PreparedTableCell(
                id: draft.id, attributedText: draft.content.copy() as! NSAttributedString,
                isHeader: draft.isHeader, alignment: draft.alignment,
                contentHeight: min(tableRowHeight, max(1, ceil(measured.height)))
            )
        }
        let layout = CachedTableLayout(columnWidths: widths,
                                       columnOffsets: offsets,
                                       cells: prepared,
                                       totalWidth: widths.reduce(0, +))
        tableRenderCache[info.anchor] = layout
        tableRenderCacheBuildCount += 1
        return layout
    }

    /// Baseline offset (within the line fragment) for the marker anchored at
    /// `charIndex`. An *empty* item's anchor is its trailing newline, and
    /// `location(forGlyphAt:)` is unreliable for control glyphs — the drawn
    /// box/bullet sat visibly low, then jumped up when the first typed glyph
    /// arrived. Derive the baseline from the fragment instead: the extra
    /// lineHeightMultiple leading sits above the text, so the baseline hangs
    /// at the bottom of the fragment minus the descent.
    private func markerBaselineOffset(glyph: Int, charIndex: Int, lineRect: NSRect) -> CGFloat {
        if let storage = textStorage, charIndex < storage.length,
           (storage.string as NSString).character(at: charIndex) == 0x0A {
            return lineRect.height + bulletFont.descender
        }
        return location(forGlyphAt: glyph).y
    }

    /// Native-style task checkbox: accent-filled rounded square with a white
    /// checkmark when checked; bordered empty box when not — matching modern
    /// macOS checkbox appearance (and the user's accent color).
    private func drawCheckbox(checked: Bool, atCharIndex charIndex: Int, origin: NSPoint) {
        checkboxRects[charIndex] = nil
        guard charIndex < numberOfGlyphs else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphLoc = location(forGlyphAt: glyph)

        let size: CGFloat = max(12, min(16, bulletFont.pointSize * 0.9))
        let x = origin.x + lineRect.minX + glyphLoc.x - size - 6
        // Center the box on the text's cap height, anchored to the baseline.
        let baseline = origin.y + lineRect.minY
            + markerBaselineOffset(glyph: glyph, charIndex: charIndex, lineRect: lineRect)
        let y = baseline - bulletFont.capHeight / 2 - size / 2
        let rect = NSRect(x: x, y: y, width: size, height: size)
        checkboxRects[charIndex] = minimumHitRect(containing: rect)
        let box = NSBezierPath(roundedRect: rect, xRadius: size * 0.28, yRadius: size * 0.28)

        if checked {
            NSColor.controlAccentColor.setFill()
            box.fill()
            // white checkmark (drawing context is flipped: +y is down)
            let check = NSBezierPath()
            check.lineWidth = max(1.5, size * 0.13)
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: rect.minX + size * 0.26, y: rect.minY + size * 0.55))
            check.line(to: NSPoint(x: rect.minX + size * 0.43, y: rect.minY + size * 0.72))
            check.line(to: NSPoint(x: rect.minX + size * 0.74, y: rect.minY + size * 0.32))
            NSColor.white.setStroke()
            check.stroke()
        } else {
            NSColor.textBackgroundColor.setFill()
            box.fill()
            NSColor.tertiaryLabelColor.setStroke()
            box.lineWidth = 1
            box.stroke()
        }
    }

    private func minimumHitRect(centeredAt center: NSPoint,
                                size: CGFloat = 40) -> NSRect {
        NSRect(x: center.x - size / 2, y: center.y - size / 2,
               width: size, height: size)
    }

    private func minimumHitRect(containing rect: NSRect,
                                size: CGFloat = 40) -> NSRect {
        NSRect(x: rect.midX - max(size, rect.width) / 2,
               y: rect.midY - max(size, rect.height) / 2,
               width: max(size, rect.width),
               height: max(size, rect.height))
    }

    private func drawLeftMarker(_ s: String, atCharIndex charIndex: Int, origin: NSPoint, color: NSColor) {
        guard charIndex < numberOfGlyphs else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphLoc = location(forGlyphAt: glyph)
        let attrs: [NSAttributedString.Key: Any] = [.font: bulletFont, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        let x = origin.x + lineRect.minX + glyphLoc.x - size.width - 5
        // Align the marker's baseline with the text baseline (glyphLoc.y is the
        // baseline offset within the fragment) — centering in the fragment sat
        // markers visibly high once line-height multiples stretched the line.
        let y = origin.y + lineRect.minY - bulletFont.ascender
            + markerBaselineOffset(glyph: glyph, charIndex: charIndex, lineRect: lineRect)
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    private func drawImage(_ img: NSImage, atCharIndex charIndex: Int, origin: NSPoint) {
        guard charIndex < numberOfGlyphs, let container = textContainers.first else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let available = max(1, container.size.width - container.lineFragmentPadding * 2 - 24)
        let maxW = max(1, min(imageMaxWidth, available))
        guard img.size.width > 0, img.size.height > 0 else { return }
        let scale = min(1, maxW / img.size.width)
        let w = img.size.width * scale
        let h = img.size.height * scale
        let containerRect = NSRect(x: lineRect.minX + 12,
                                   y: lineRect.minY + 4,
                                   width: w, height: h)
        imageRects[charIndex] = containerRect
        let drawRect = containerRect.offsetBy(dx: origin.x, dy: origin.y)
        img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: nil)
        let selected = selectedImageAnchor == charIndex
        if selected || !imageUsesAlphaChannel(img) {
            drawImageOutline(in: drawRect, cornerRadius: 0, selected: selected)
        }
    }

    private func drawImageFallback(alt: String, atCharIndex charIndex: Int, origin: NSPoint) {
        guard charIndex < numberOfGlyphs, let container = textContainers.first else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let available = max(1, container.size.width - container.lineFragmentPadding * 2 - 24)
        let width = max(1, min(imageMaxWidth, available))
        let containerRect = NSRect(x: lineRect.minX + 12,
                                   y: lineRect.minY + 4,
                                   width: width, height: max(32, lineRect.height - 8))
        imageRects[charIndex] = containerRect
        let rect = containerRect.offsetBy(dx: origin.x, dy: origin.y)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        drawImageOutline(in: rect, cornerRadius: 6,
                         selected: selectedImageAnchor == charIndex)

        let label = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (label.isEmpty ? "Image" : label) as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let size = text.size(withAttributes: attrs)
        let labelRect = NSRect(x: rect.minX + 12, y: rect.midY - size.height / 2,
                               width: max(0, rect.width - 24), height: size.height)
        text.draw(in: labelRect, withAttributes: attrs)
    }

    private func drawImageOutline(in rect: NSRect, cornerRadius: CGFloat, selected: Bool) {
        let lineWidth: CGFloat = selected ? 2 : 1
        let inset = lineWidth / 2
        let outlineRect = rect.insetBy(dx: inset, dy: inset)
        let radius = max(0, cornerRadius - inset)
        let outline = cornerRadius > 0
            ? NSBezierPath(roundedRect: outlineRect, xRadius: radius, yRadius: radius)
            : NSBezierPath(rect: outlineRect)
        (selected ? NSColor.systemBlue : imageOutlineColor).setStroke()
        outline.lineWidth = lineWidth
        outline.stroke()
    }

    /// Transparent artwork should keep its natural silhouette instead of
    /// revealing the rectangular bounds of the image container. Checking the
    /// backing image metadata avoids scanning large images during a redraw.
    private func imageUsesAlphaChannel(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        switch cgImage.alphaInfo {
        case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return true
        }
    }

    private var imageOutlineColor: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? NSColor.white.withAlphaComponent(0.10)
                        : NSColor.black.withAlphaComponent(0.10)
        }
    }
}
