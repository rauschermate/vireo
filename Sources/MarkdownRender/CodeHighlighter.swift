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

    public func tokens(in code: String, offset: Int, isDark: Bool) -> [Token] {
        var out: [Token] = []
        let commentColor: NSColor = isDark ? .init(white: 0.55, alpha: 1) : .init(white: 0.5, alpha: 1)
        let stringColor: NSColor = isDark ? .systemGreen : .systemRed
        let numberColor: NSColor = isDark ? .systemTeal : .systemPurple
        let keywordColor: NSColor = isDark ? .systemPink : .systemBlue

        func add(_ regex: String, _ color: NSColor, group: Int = 0) {
            guard let re = try? NSRegularExpression(pattern: regex, options: [.anchorsMatchLines]) else { return }
            let full = NSRange(code.startIndex..., in: code)
            for m in re.matches(in: code, range: full) {
                let r = m.range(at: group)
                guard r.location != NSNotFound else { continue }
                out.append(Token(range: NSRange(location: r.location + offset, length: r.length), color: color))
            }
        }

        // strings first, then let comments/keywords over-paint where relevant
        add(#""(?:[^"\\]|\\.)*""#, stringColor)
        add(#"'(?:[^'\\]|\\.)*'"#, stringColor)
        add(#"\b\d+(?:\.\d+)?\b"#, numberColor)
        add(#"(//[^\n]*|#[^\n]*)"#, commentColor, group: 1)

        // keywords
        if let re = try? NSRegularExpression(pattern: #"\b[A-Za-z_]\w*\b"#) {
            let full = NSRange(code.startIndex..., in: code)
            for m in re.matches(in: code, range: full) {
                if let r = Range(m.range, in: code), Self.keywords.contains(String(code[r])) {
                    out.append(Token(range: NSRange(location: m.range.location + offset, length: m.range.length),
                                     color: keywordColor))
                }
            }
        }
        return out
    }
}
