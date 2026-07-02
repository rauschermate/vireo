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
        var changed = false
        for i in 0..<count {
            let charIndex = charIndexes[i]
            if charIndex < storage.length,
               storage.attribute(.vireoMarker, at: charIndex, effectiveRange: nil) != nil {
                newProps[i] = .null
                changed = true
            } else {
                newProps[i] = props[i]
            }
        }
        guard changed else { return 0 }
        newProps.withUnsafeBufferPointer { buf in
            self.setGlyphs(glyphs, properties: buf.baseAddress!,
                           characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
        }
        return count
    }

    // MARK: Draw bullets / checkboxes / images

    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.vireoBullet, in: charRange) { value, range, _ in
            guard let s = value as? String else { return }
            drawLeftMarker(s, atCharIndex: range.location, origin: origin, color: markerColor)
        }
        storage.enumerateAttribute(.vireoCheckbox, in: charRange) { value, range, _ in
            guard let n = value as? NSNumber else { return }
            drawLeftMarker(n.boolValue ? "☑" : "☐", atCharIndex: range.location,
                           origin: origin, color: n.boolValue ? .controlAccentColor : markerColor)
        }
        storage.enumerateAttribute(.vireoImage, in: charRange) { value, range, _ in
            guard let src = value as? String, let img = imageProvider?(src) else { return }
            drawImage(img, atCharIndex: range.location, origin: origin)
        }
        storage.enumerateAttribute(.vireoTable, in: charRange) { value, range, _ in
            guard let n = value as? NSNumber, tables.indices.contains(n.intValue) else { return }
            drawTable(tables[n.intValue], atCharIndex: range.location, origin: origin, storage: storage)
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

    private func drawLeftMarker(_ s: String, atCharIndex charIndex: Int, origin: NSPoint, color: NSColor) {
        guard charIndex < numberOfGlyphs else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphLoc = location(forGlyphAt: glyph)
        let attrs: [NSAttributedString.Key: Any] = [.font: bulletFont, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        let x = origin.x + lineRect.minX + glyphLoc.x - size.width - 5
        let y = origin.y + lineRect.minY + (lineRect.height - size.height) / 2
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
