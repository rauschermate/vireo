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

    // Table drawing config (set on each restyle).
    public var tables: [TableInfo] = []
    public var tableRowHeight: CGFloat = 40
    public var tableFont: NSFont = .systemFont(ofSize: 15)
    public var tableHeaderFont: NSFont = .systemFont(ofSize: 15, weight: .semibold)
    /// Cell frames from the current draw pass, in text-view coordinates. The
    /// editor uses these for direct cell hit testing and its native overlay.
    public private(set) var tableCellGeometries: [TableCellID: TableCellGeometry] = [:]
    public private(set) var tableRects: [Int: NSRect] = [:]

    public func beginTableGeometryPass() {
        tableCellGeometries.removeAll(keepingCapacity: true)
        tableRects.removeAll(keepingCapacity: true)
    }

    public func tableCell(at point: NSPoint) -> TableCellGeometry? {
        tableCellGeometries.values.first { $0.rect.contains(point) }
    }

    public func geometry(for id: TableCellID) -> TableCellGeometry? {
        tableCellGeometries[id]
    }

    // List/heading collapse and hover state (set on each restyle / mouse move).
    public var listMarkers: [ListMarker] = []
    public var taskMarks: [TaskMark] = []
    public var headingMarks: [HeadingMark] = []
    public var collapsedAnchors: Set<Int> = []
    public var hoveredAnchor: Int?

    /// Hit-test rects recorded during drawing (text-view coordinates):
    /// chevron toggles and collapsed-`…` expanders, keyed by item anchor.
    public private(set) var chevronRects: [Int: NSRect] = [:]
    public private(set) var dotsRects: [Int: NSRect] = [:]
    /// Rendered image hit targets in text-view coordinates, keyed by source anchor.
    /// `MarkdownTextView` uses these for the native edit/remove affordance.
    public private(set) var imageRects: [Int: NSRect] = [:]

    public override init() {
        super.init()
        self.delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.delegate = self
    }

    // MARK: Hide markers by emitting null glyphs

    public func layoutManager(_ layoutManager: NSLayoutManager,
                              shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                              properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                              characterIndexes charIndexes: UnsafePointer<Int>,
                              font: NSFont,
                              forGlyphRange glyphRange: NSRange) -> Int {
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

    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        func isCollapsedAway(_ index: Int) -> Bool {
            index < storage.length
                && storage.attribute(.vireoCollapsed, at: index, effectiveRange: nil) != nil
        }

        drawListGuides(visibleCharRange: charRange, origin: origin)

        storage.enumerateAttribute(.vireoBullet, in: charRange) { value, range, _ in
            guard let s = value as? String, !isCollapsedAway(range.location) else { return }
            let anchor = range.location
            let collapsed = collapsedAnchors.contains(anchor)
            let color: NSColor = collapsed ? .controlAccentColor : markerColor
            if collapsed { drawCollapseHalo(atCharIndex: anchor, markerText: s, origin: origin) }
            drawLeftMarker(s, atCharIndex: anchor, origin: origin, color: color)
            drawListAdornments(anchor: anchor, markerText: s, origin: origin)
        }
        storage.enumerateAttribute(.vireoCheckbox, in: charRange) { value, range, _ in
            guard let n = value as? NSNumber, !isCollapsedAway(range.location) else { return }
            drawCheckbox(checked: n.boolValue, atCharIndex: range.location, origin: origin)
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
                  let info = tables.first(where: { $0.anchor == n.intValue }),
                  !isCollapsedAway(range.location) else { return }
            drawTable(info, atCharIndex: range.location, origin: origin, storage: storage)
        }
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

    private func markerGeometry(anchor: Int, markerText: String?) -> (lineRect: NSRect, baseline: CGFloat, textX: CGFloat, markerWidth: CGFloat)? {
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
        return (lineRect, lineRect.minY + loc.y, lineRect.minX + loc.x, width)
    }

    /// Chevron (hover / collapsed) and the collapsed `…` expander.
    private func drawListAdornments(anchor: Int, markerText: String?, origin: NSPoint) {
        let collapsed = collapsedAnchors.contains(anchor)
        let hovered = hoveredAnchor == anchor
        chevronRects[anchor] = nil
        dotsRects[anchor] = nil
        guard collapsed || hovered, subtree(forAnchor: anchor) != nil,
              let geo = markerGeometry(anchor: anchor, markerText: markerText) else { return }

        // Chevron sits left of the drawn marker; points right when collapsed.
        let center = NSPoint(x: origin.x + geo.textX - geo.markerWidth - 5 - 12,
                             y: origin.y + geo.baseline - bulletFont.capHeight / 2)
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
        chevronRects[anchor] = NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)

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
            dotsRects[anchor] = NSRect(x: at.x - 4, y: at.y, width: size.width + 12, height: size.height)
        }
    }

    /// Heading fold chevron (hover / collapsed) and the collapsed `…` expander —
    /// same interaction as list items, sized to the heading's own font.
    private func drawHeadingAdornments(anchor: Int, origin: NSPoint, storage: NSTextStorage) {
        let collapsed = collapsedAnchors.contains(anchor)
        let hovered = hoveredAnchor == anchor
        chevronRects[anchor] = nil
        dotsRects[anchor] = nil
        guard collapsed || hovered, subtree(forAnchor: anchor) != nil,
              anchor < numberOfGlyphs else { return }
        let glyph = glyphIndexForCharacter(at: anchor)
        guard glyph < numberOfGlyphs else { return }
        let font = (storage.attribute(.font, at: anchor, effectiveRange: nil) as? NSFont) ?? bulletFont
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let loc = location(forGlyphAt: glyph)
        let baseline = origin.y + lineRect.minY + loc.y
        let textX = origin.x + lineRect.minX + loc.x

        // Chevron in the left margin of the heading text; points right when
        // collapsed (matches the list chevron's geometry and colors).
        let center = NSPoint(x: textX - 14, y: baseline - font.capHeight / 2)
        if collapsed {
            let d: CGFloat = 18
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - d / 2, y: center.y - d / 2,
                                        width: d, height: d)).fill()
        }
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
        chevronRects[anchor] = NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)

        // `…` after the collapsed heading's text; click to expand.
        if collapsed {
            let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let dots = "…" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font,
                                                        .foregroundColor: NSColor.tertiaryLabelColor]
            let size = dots.size(withAttributes: attrs)
            let at = NSPoint(x: origin.x + used.maxX + 8, y: baseline - font.ascender)
            dots.draw(at: at, withAttributes: attrs)
            dotsRects[anchor] = NSRect(x: at.x - 4, y: at.y, width: size.width + 12, height: size.height)
        }
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
    private func drawListGuides(visibleCharRange: NSRange, origin: NSPoint) {
        guard let container = textContainers.first, let storage = textStorage else { return }
        let all: [(anchor: Int, subtree: NSRange?, text: String?)] =
            listMarkers.map { ($0.anchor, $0.subtreeRange, $0.text) }
            + taskMarks.map { ($0.anchor, $0.subtreeRange, nil) }

        for entry in all {
            guard let sub = entry.subtree,
                  !collapsedAnchors.contains(entry.anchor),
                  NSIntersectionRange(sub, visibleCharRange).length > 0
                    || NSLocationInRange(entry.anchor, visibleCharRange),
                  entry.anchor < storage.length,
                  storage.attribute(.vireoCollapsed, at: entry.anchor, effectiveRange: nil) == nil,
                  let geo = markerGeometry(anchor: entry.anchor, markerText: entry.text) else { continue }

            let subGlyphs = glyphRange(forCharacterRange: sub, actualCharacterRange: nil)
            guard subGlyphs.length > 0 else { continue }
            let bounds = boundingRect(forGlyphRange: subGlyphs, in: container)
            guard bounds.height > 1 else { continue }

            let x = origin.x + geo.textX - 5 - geo.markerWidth / 2
            let top = origin.y + geo.lineRect.maxY + 2
            let bottom = origin.y + bounds.maxY - 3
            guard bottom > top else { continue }
            let line = NSBezierPath()
            line.lineWidth = 1
            line.move(to: NSPoint(x: x, y: top))
            line.line(to: NSPoint(x: x, y: bottom))
            NSColor.separatorColor.setStroke()
            line.stroke()
        }
    }

    private func drawTable(_ info: TableInfo, atCharIndex charIndex: Int, origin: NSPoint, storage: NSTextStorage) {
        guard charIndex < numberOfGlyphs else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let src = storage.string as NSString
        let top = origin.y + lineRect.minY
        let left = origin.x + lineRect.minX
        let pad: CGFloat = 10
        let rh = tableRowHeight
        let cols = info.columnCount
        guard cols > 0 else { return }

        func cellText(_ cell: TableCell) -> String {
            let r = NSIntersectionRange(cell.range, NSRange(location: 0, length: src.length))
            return r.length > 0 ? src.substring(with: r) : ""
        }
        func attrs(header: Bool) -> [NSAttributedString.Key: Any] {
            [.font: header ? tableHeaderFont : tableFont, .foregroundColor: NSColor.labelColor]
        }

        // Column widths from the widest cell per column.
        var widths = [CGFloat](repeating: 0, count: cols)
        for row in info.rows {
            for cell in row.cells where cell.column < cols {
                let w = (cellText(cell) as NSString).size(withAttributes: attrs(header: row.isHeader)).width
                widths[cell.column] = max(widths[cell.column], w)
            }
        }
        var colW = widths.map { max(72, $0 + pad * 2) }
        let available = max(72, lineRect.width)
        let desired = colW.reduce(0, +)
        if desired < available {
            let extra = (available - desired) / CGFloat(cols)
            colW = colW.map { $0 + extra }
        } else if desired > available {
            let minimumTotal = CGFloat(cols) * 72
            if minimumTotal < available {
                let scale = (available - minimumTotal) / max(1, desired - minimumTotal)
                colW = colW.map { 72 + ($0 - 72) * scale }
            }
        }
        let totalW = colW.reduce(0, +)
        let rowCount = info.rows.count
        let tableH = CGFloat(rowCount) * rh

        var xs = [CGFloat]()
        var acc = left
        for w in colW { xs.append(acc); acc += w }
        let right = left + totalW
        tableRects[info.anchor] = NSRect(x: left, y: top, width: totalW, height: tableH)

        // Header background.
        NSColor.secondaryLabelColor.withAlphaComponent(0.10)
            .setFill()
        NSRect(x: left, y: top, width: totalW, height: rh).fill()

        // Grid lines.
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for r in 0...rowCount {
            let y = top + CGFloat(r) * rh
            grid.move(to: NSPoint(x: left, y: y))
            grid.line(to: NSPoint(x: right, y: y))
        }
        for i in 0...cols {
            let x = i < xs.count ? xs[i] : right
            grid.move(to: NSPoint(x: x, y: top))
            grid.line(to: NSPoint(x: x, y: top + tableH))
        }
        NSColor.separatorColor.setStroke()
        grid.stroke()

        // Cell text.
        for (rIdx, row) in info.rows.enumerated() {
            let y = top + CGFloat(rIdx) * rh
            for cell in row.cells where cell.column < cols {
                let cellX = xs[cell.column]
                let cellWidth = colW[cell.column]
                let cellRect = NSRect(x: cellX, y: y, width: cellWidth, height: rh)
                let id = TableCellID(tableAnchor: info.anchor, row: rIdx,
                                     column: cell.column)
                tableCellGeometries[id] = TableCellGeometry(
                    id: id, rect: cellRect, isHeader: row.isHeader,
                    alignment: cell.alignment
                )

                let sourceRange = NSIntersectionRange(
                    cell.range, NSRange(location: 0, length: storage.length)
                )
                let content = NSMutableAttributedString(
                    attributedString: sourceRange.length > 0
                        ? storage.attributedSubstring(from: sourceRange)
                        : NSAttributedString(string: "")
                )
                // Marker characters inside a cell (emphasis, links, code) are
                // source plumbing, not content drawn into the grid.
                if content.length > 0 {
                    var hidden: [NSRange] = []
                    content.enumerateAttribute(.vireoMarker,
                                               in: NSRange(location: 0, length: content.length)) {
                        value, range, _ in
                        if value != nil { hidden.append(range) }
                    }
                    for range in hidden.reversed() { content.deleteCharacters(in: range) }
                }

                let fullContent = NSRange(location: 0, length: content.length)
                if fullContent.length > 0 {
                    content.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                         range: fullContent)
                    content.enumerateAttribute(.vireoLink, in: fullContent) { value, range, _ in
                        if value != nil {
                            content.addAttribute(.foregroundColor, value: NSColor.linkColor,
                                                 range: range)
                        }
                    }
                }
                if content.length == 0 {
                    content.append(NSAttributedString(string: "", attributes: attrs(header: row.isHeader)))
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                switch cell.alignment {
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                default: paragraph.alignment = .left
                }
                if fullContent.length > 0 {
                    content.addAttribute(.paragraphStyle, value: paragraph, range: fullContent)
                    if content.attribute(.font, at: 0, effectiveRange: nil) == nil {
                        content.addAttribute(.font,
                                             value: row.isHeader ? tableHeaderFont : tableFont,
                                             range: fullContent)
                    }
                }
                let measured = content.boundingRect(
                    with: NSSize(width: max(1, cellRect.width - pad * 2), height: rh),
                    options: [.usesLineFragmentOrigin]
                )
                let contentHeight = min(rh, max(1, ceil(measured.height)))
                let drawRect = NSRect(x: cellRect.minX + pad,
                                      y: cellRect.midY - contentHeight / 2,
                                      width: max(1, cellRect.width - pad * 2),
                                      height: contentHeight)
                content.draw(with: drawRect,
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             context: nil)
            }
        }
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
        let rect = NSRect(x: origin.x + lineRect.minX + 12,
                          y: origin.y + lineRect.minY + 4,
                          width: w, height: h)
        imageRects[charIndex] = rect
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: nil)
        imageOutlineColor.setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    private func drawImageFallback(alt: String, atCharIndex charIndex: Int, origin: NSPoint) {
        guard charIndex < numberOfGlyphs, let container = textContainers.first else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let available = max(1, container.size.width - container.lineFragmentPadding * 2 - 24)
        let width = max(1, min(imageMaxWidth, available))
        let rect = NSRect(x: origin.x + lineRect.minX + 12,
                          y: origin.y + lineRect.minY + 4,
                          width: width, height: max(32, lineRect.height - 8))
        imageRects[charIndex] = rect
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        imageOutlineColor.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: 5.5, yRadius: 5.5)
        outline.lineWidth = 1
        outline.stroke()

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

    private var imageOutlineColor: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? NSColor.white.withAlphaComponent(0.10)
                        : NSColor.black.withAlphaComponent(0.10)
        }
    }
}
