import AppKit
import MarkdownEngine

/// AppKit objects and attribute dictionaries shared by every run in one
/// render. Constructing fonts and paragraph styles per AST node dominated
/// formatting-dense documents even before TextKit saw the result.
@MainActor
struct RenderStyleCache {
    let bodyParagraph: NSParagraphStyle
    let bodyAttributes: [NSAttributedString.Key: Any]
    let headingAttributes: [Int: [NSAttributedString.Key: Any]]
    let quoteAttributes: [NSAttributedString.Key: Any]
    let codeBlockAttributes: [NSAttributedString.Key: Any]
    let codeFenceParagraph: NSParagraphStyle
    let tableHeaderRowAttributes: [NSAttributedString.Key: Any]
    let tableBodyRowAttributes: [NSAttributedString.Key: Any]
    let ruleAttributes: [NSAttributedString.Key: Any]
    let inlineCodeAttributes: [NSAttributedString.Key: Any]
    let listParagraphs: [Int: NSParagraphStyle]
    let tableRowParagraph: NSParagraphStyle
    let tableLastRowParagraph: NSParagraphStyle
    let tableSeparatorParagraph: NSParagraphStyle
    let metadataHiddenParagraph: NSParagraphStyle
    let metadataVisibleParagraph: NSParagraphStyle
    let collapsedParagraph: NSParagraphStyle
    let bodyFont: NSFont
    let boldFont: NSFont
    let italicFont: NSFont
    let boldItalicFont: NSFont

    init(theme: Theme, parsed: ParsedMarkdown,
         tableScrollerGutter: CGFloat) {
        let body = NSMutableParagraphStyle()
        body.lineHeightMultiple = theme.lineHeightMultiple
        body.paragraphSpacing = theme.baseSize * 0.5
        bodyParagraph = body
        bodyFont = theme.bodyFont
        boldFont = theme.boldFont
        italicFont = theme.italicFont
        boldItalicFont = theme.boldItalicFont
        bodyAttributes = [
            .font: bodyFont,
            .foregroundColor: theme.textColor,
            .paragraphStyle: body,
        ]

        var headings: [Int: [NSAttributedString.Key: Any]] = [:]
        for level in 1...6 {
            let paragraph = body.mutableCopy() as! NSMutableParagraphStyle
            paragraph.paragraphSpacingBefore = theme.baseSize * 0.8
            paragraph.paragraphSpacing = theme.baseSize * 0.3
            headings[level] = [
                .font: theme.headingFont(level),
                .paragraphStyle: paragraph,
            ]
        }
        headingAttributes = headings

        let quote = body.mutableCopy() as! NSMutableParagraphStyle
        quote.firstLineHeadIndent = 20
        quote.headIndent = 20
        quoteAttributes = [
            .foregroundColor: theme.secondaryColor,
            .paragraphStyle: quote,
            .font: italicFont,
            .vireoBlockQuote: theme.quoteBarColor,
        ]

        let code = NSMutableParagraphStyle()
        code.lineHeightMultiple = 1.2
        code.firstLineHeadIndent = 12
        code.headIndent = 12
        codeBlockAttributes = [
            .font: theme.codeFont,
            .foregroundColor: theme.codeColor,
            .paragraphStyle: code,
            .vireoCodeBlock: theme.codeBackground,
        ]
        let codeFence = NSMutableParagraphStyle()
        codeFence.minimumLineHeight = 8 * theme.zoom
        codeFence.maximumLineHeight = 8 * theme.zoom
        codeFence.firstLineHeadIndent = 12
        codeFence.headIndent = 12
        codeFenceParagraph = codeFence
        inlineCodeAttributes = [
            .font: theme.codeFont,
            .foregroundColor: theme.inlineCodeColor,
            // The layout manager draws the pill; `.backgroundColor` stays so
            // TextKit still hands per-line-fragment rects to fillBackgroundRectArray.
            .backgroundColor: theme.codeBackground,
            .vireoInlineCode: true,
        ]
        tableHeaderRowAttributes = [
            .font: theme.tableHeaderFont,
            .foregroundColor: theme.textColor,
        ]
        tableBodyRowAttributes = [
            .font: theme.tableFont,
            .foregroundColor: theme.textColor,
        ]
        let rule = body.mutableCopy() as! NSMutableParagraphStyle
        rule.minimumLineHeight = 24 * theme.zoom
        rule.maximumLineHeight = 24 * theme.zoom
        ruleAttributes = [
            .paragraphStyle: rule,
        ]

        var lists: [Int: NSParagraphStyle] = [:]
        for block in parsed.blockRuns {
            guard case .listItem(let depth, _) = block.kind,
                  lists[depth] == nil else { continue }
            let paragraph = body.mutableCopy() as! NSMutableParagraphStyle
            let indent = CGFloat(depth + 1) * 22
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent
            paragraph.paragraphSpacing = theme.baseSize * 0.15
            lists[depth] = paragraph
        }
        listParagraphs = lists

        let row = NSMutableParagraphStyle()
        row.minimumLineHeight = theme.tableRowHeight
        row.maximumLineHeight = theme.tableRowHeight
        tableRowParagraph = row
        let lastRow = row.mutableCopy() as! NSMutableParagraphStyle
        lastRow.minimumLineHeight = theme.tableRowHeight + tableScrollerGutter
        lastRow.maximumLineHeight = theme.tableRowHeight + tableScrollerGutter
        tableLastRowParagraph = lastRow
        let separator = NSMutableParagraphStyle()
        separator.minimumLineHeight = 0.01
        separator.maximumLineHeight = 0.01
        tableSeparatorParagraph = separator
        let metadataHidden = NSMutableParagraphStyle()
        metadataHidden.minimumLineHeight = 0.01
        metadataHidden.maximumLineHeight = 0.01
        metadataHidden.paragraphSpacing = 0
        metadataHiddenParagraph = metadataHidden
        let metadataVisible = NSMutableParagraphStyle()
        metadataVisible.minimumLineHeight = 30
        metadataVisible.maximumLineHeight = 30
        metadataVisible.paragraphSpacing = theme.baseSize * 0.25
        metadataVisibleParagraph = metadataVisible
        let collapsed = NSMutableParagraphStyle()
        collapsed.minimumLineHeight = 0.01
        collapsed.maximumLineHeight = 0.01
        collapsedParagraph = collapsed
    }

    func inlineFont(bold: Bool, italic: Bool) -> NSFont {
        if bold && italic { return boldItalicFont }
        if bold { return boldFont }
        if italic { return italicFont }
        return bodyFont
    }
}
