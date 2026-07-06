import AppKit

/// Lightweight, language-agnostic syntax highlighter. Not a full tokenizer —
/// it colors comments, strings, numbers and a common keyword set well enough to
/// look native across languages. (Phase 3 can swap in tree-sitter.)
public struct CodeHighlighter {
    public init() {}

    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "class",
        "struct", "enum", "protocol", "import", "public", "private", "static",
        "guard", "switch", "case", "default", "in", "do", "try", "catch", "throw",
        "async", "await", "extension", "self", "nil", "true", "false", "def",
        "int", "float", "double", "string", "bool", "void", "const", "new",
        "function", "type", "interface", "export", "from", "def", "print",
        "and", "or", "not", "None", "True", "False", "package", "map", "range",
    ]

    public struct Token {
        public var range: NSRange
        public var color: NSColor
    }

    // Compiling an NSRegularExpression is expensive; these patterns never
    // change, so compile them once and reuse across every code block / render.
    private static let stringDoubleRE = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#, options: [.anchorsMatchLines])
    private static let stringSingleRE = try! NSRegularExpression(pattern: #"'(?:[^'\\]|\\.)*'"#, options: [.anchorsMatchLines])
    private static let numberRE = try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#, options: [.anchorsMatchLines])
    private static let commentRE = try! NSRegularExpression(pattern: #"(//[^\n]*|#[^\n]*)"#, options: [.anchorsMatchLines])
    private static let identifierRE = try! NSRegularExpression(pattern: #"\b[A-Za-z_]\w*\b"#)

    public func tokens(in code: String, offset: Int, isDark: Bool) -> [Token] {
        var out: [Token] = []
        let commentColor: NSColor = isDark ? .init(white: 0.55, alpha: 1) : .init(white: 0.5, alpha: 1)
        let stringColor: NSColor = isDark ? .systemGreen : .systemRed
        let numberColor: NSColor = isDark ? .systemTeal : .systemPurple
        let keywordColor: NSColor = isDark ? .systemPink : .systemBlue
        let full = NSRange(code.startIndex..., in: code)

        func add(_ re: NSRegularExpression, _ color: NSColor, group: Int = 0) {
            for m in re.matches(in: code, range: full) {
                let r = m.range(at: group)
                guard r.location != NSNotFound else { continue }
                out.append(Token(range: NSRange(location: r.location + offset, length: r.length), color: color))
            }
        }

        // strings first, then let comments/keywords over-paint where relevant
        add(Self.stringDoubleRE, stringColor)
        add(Self.stringSingleRE, stringColor)
        add(Self.numberRE, numberColor)
        add(Self.commentRE, commentColor, group: 1)

        // keywords
        for m in Self.identifierRE.matches(in: code, range: full) {
            if let r = Range(m.range, in: code), Self.keywords.contains(String(code[r])) {
                out.append(Token(range: NSRange(location: m.range.location + offset, length: m.range.length),
                                 color: keywordColor))
            }
        }
        return out
    }
}
