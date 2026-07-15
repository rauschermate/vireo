import AppKit

/// Custom attributed-string keys used across render + editor.
public extension NSAttributedString.Key {
    /// Marks syntax-delimiter glyphs the layout manager should hide (NSNumber bool).
    static let vireoMarker = NSAttributedString.Key("vireoMarker")
    /// Link destination carried on the visible link text (NSString).
    static let vireoLink = NSAttributedString.Key("vireoLink")
    /// Image source on the (hidden) anchor char; layout manager draws it (NSString).
    static let vireoImage = NSAttributedString.Key("vireoImage")
    /// Image alt text on the draw anchor, used for a calm missing/loading fallback.
    static let vireoImageAlt = NSAttributedString.Key("vireoImageAlt")
    /// Bullet/number text drawn left of this (visible) char (NSString).
    static let vireoBullet = NSAttributedString.Key("vireoBullet")
    /// Task checkbox state drawn left of this (visible) char (NSNumber bool).
    static let vireoCheckbox = NSAttributedString.Key("vireoCheckbox")
    /// Table index (into ParsedMarkdown.tables) on the hidden anchor char (NSNumber).
    static let vireoTable = NSAttributedString.Key("vireoTable")
    /// Range hidden because an ancestor list item or heading is collapsed (NSNumber bool).
    static let vireoCollapsed = NSAttributedString.Key("vireoCollapsed")
    /// Foldable heading's first visible char; value = level (NSNumber). The
    /// layout manager hit-tests these for the fold chevron / `…` expander.
    static let vireoHeading = NSAttributedString.Key("vireoHeading")
    /// Char whose glyph is substituted with a typographic arrow → (NSNumber bool).
    static let vireoArrow = NSAttributedString.Key("vireoArrow")
}

/// Visual design tokens. A single `zoom` factor scales the whole type system
/// proportionally so headings, body and code stay balanced (PRD §8).
public struct Theme: Sendable {
    public var zoom: CGFloat

    public init(zoom: CGFloat = 1.0) {
        self.zoom = zoom
    }

    // Type scale (points at zoom = 1).
    public var baseSize: CGFloat { 16 * zoom }
    public var codeSize: CGFloat { 14 * zoom }
    public var lineHeightMultiple: CGFloat { 1.35 }
    public var contentMaxWidth: CGFloat { 640 }

    public func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 30 * zoom
        case 2: return 24 * zoom
        case 3: return 20 * zoom
        case 4: return 17 * zoom
        default: return baseSize
        }
    }

    // Fonts.
    public var bodyFont: NSFont { .systemFont(ofSize: baseSize, weight: .regular) }
    public func headingFont(_ level: Int) -> NSFont {
        .systemFont(ofSize: headingSize(level), weight: level <= 2 ? .bold : .semibold)
    }
    public var codeFont: NSFont { .monospacedSystemFont(ofSize: codeSize, weight: .regular) }
    public var tableFont: NSFont { .systemFont(ofSize: baseSize * 0.95, weight: .regular) }
    public var tableHeaderFont: NSFont { .systemFont(ofSize: baseSize * 0.95, weight: .semibold) }
    public var tableRowHeight: CGFloat { ceil(baseSize * 1.35) + 16 }
    /// Reserved below editor tables for the native horizontal scroller. Static
    /// renderers leave this disabled and keep their previous compact spacing.
    public var tableScrollerGutter: CGFloat { 16 }
    public var boldFont: NSFont { .systemFont(ofSize: baseSize, weight: .semibold) }
    public var italicFont: NSFont { Self.italic(of: bodyFont) }
    public var boldItalicFont: NSFont { Self.italic(of: boldFont) }

    /// `NSFontManager.convert` acquires a global lock and is comparatively slow;
    /// a full render asks for the italic/bold-italic face once per inline run
    /// (thousands of times on a large document). Memoize by point size + weight
    /// so each distinct face is derived only once for the whole process.
    private static let italicLock = NSLock()
    nonisolated(unsafe) private static var italicCache: [String: NSFont] = [:]
    private static func italic(of font: NSFont) -> NSFont {
        let key = "\(font.fontName)-\(font.pointSize)"
        italicLock.lock()
        defer { italicLock.unlock() }
        if let cached = italicCache[key] { return cached }
        let derived = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        italicCache[key] = derived
        return derived
    }

    // Colors (all appearance-aware / dynamic).
    public var textColor: NSColor { .textColor }
    public var secondaryColor: NSColor { .secondaryLabelColor }
    public var linkColor: NSColor { .linkColor }
    public var codeColor: NSColor { .init(name: nil) { $0.isDark ? .init(white: 0.92, alpha: 1) : .init(white: 0.2, alpha: 1) } }
    public var codeBackground: NSColor { .init(name: nil) { $0.isDark ? .init(white: 1, alpha: 0.07) : .init(white: 0, alpha: 0.05) } }
    public var quoteBarColor: NSColor { .tertiaryLabelColor }
    public var ruleColor: NSColor { .separatorColor }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
