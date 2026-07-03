import AppKit
import MarkdownEngine

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

    // Table drawing config (set on each restyle).
    public var tables: [TableInfo] = []
    public var tableRowHeight: CGFloat = 40
    public var tableFont: NSFont = .systemFont(ofSize: 15)
    public var tableHeaderFont: NSFont = .systemFont(ofSize: 15, weight: .semibold)

    // List collapse/hover state (set on each restyle / mouse move).
    public var listMarkers: [ListMarker] = []
    public var taskMarks: [TaskMark] = []
    public var collapsedAnchors: Set<Int> = []
    public var hoveredAnchor: Int?

    /// Hit-test rects recorded during drawing (text-view coordinates):
    /// chevron toggles and collapsed-`…` expanders, keyed by item anchor.
    public private(set) var chevronRects: [Int: NSRect] = [:]
    public private(set) var dotsRects: [Int: NSRect] = [:]

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
        for i in 0..<count {
            let charIndex = charIndexes[i]
            guard charIndex < storage.length else { newProps[i] = props[i]; continue }
            if storage.attribute(.vireoMarker, at: charIndex, effectiveRange: nil) != nil
                || storage.attribute(.vireoCollapsed, at: charIndex, effectiveRange: nil) != nil {
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
        storage.enumerateAttribute(.vireoImage, in: charRange) { value, range, _ in
            guard let src = value as? String, let img = imageProvider?(src),
                  !isCollapsedAway(range.location) else { return }
            drawImage(img, atCharIndex: range.location, origin: origin)
        }
        storage.enumerateAttribute(.vireoTable, in: charRange) { value, range, _ in
            guard let n = value as? NSNumber,
                  let info = tables.first(where: { $0.anchor == n.intValue }),
                  !isCollapsedAway(range.location) else { return }
            drawTable(info, atCharIndex: range.location, origin: origin, storage: storage)
        }
    }

    // MARK: List collapse UI (chevrons, halo, …, guides)

    private func subtree(forAnchor anchor: Int) -> NSRange? {
        if let m = listMarkers.first(where: { $0.anchor == anchor }) { return m.subtreeRange }
        if let t = taskMarks.first(where: { $0.anchor == anchor }) { return t.subtreeRange }
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
        let colW = widths.map { $0 + pad * 2 }
        let totalW = colW.reduce(0, +)
        let rowCount = info.rows.count
        let tableH = CGFloat(rowCount) * rh

        var xs = [CGFloat]()
        var acc = left
        for w in colW { xs.append(acc); acc += w }
        let right = left + totalW

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
                let s = cellText(cell) as NSString
                let a = attrs(header: row.isHeader)
                let size = s.size(withAttributes: a)
                let cellX = xs[cell.column]
                let cellWidth = colW[cell.column]
                var tx = cellX + pad
                switch cell.alignment {
                case .center: tx = cellX + (cellWidth - size.width) / 2
                case .right: tx = cellX + cellWidth - pad - size.width
                default: break
                }
                let ty = y + (rh - size.height) / 2
                s.draw(at: NSPoint(x: tx, y: ty), withAttributes: a)
            }
        }
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
        let baseline = origin.y + lineRect.minY + glyphLoc.y
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
        let y = origin.y + lineRect.minY + glyphLoc.y - bulletFont.ascender
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    private func drawImage(_ img: NSImage, atCharIndex charIndex: Int, origin: NSPoint) {
        guard charIndex < numberOfGlyphs, let container = textContainers.first else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let maxW = container.size.width - container.lineFragmentPadding * 2
        guard img.size.width > 0 else { return }
        let scale = min(1, maxW / img.size.width)
        let w = img.size.width * scale
        let h = img.size.height * scale
        let rect = NSRect(x: origin.x + lineRect.minX + 12,
                          y: origin.y + lineRect.minY + 4,
                          width: w, height: h)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
