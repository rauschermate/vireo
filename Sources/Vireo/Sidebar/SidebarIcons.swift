import SwiftUI

/// The sidebar glyphs, drawn from SVG path data so they match the reference
/// design stroke for stroke. Each icon is authored on a 24-unit grid (12 for
/// the caret, 16 for the switcher) and scaled to its display size.
enum SidebarIcon {
    /// Hugeicons "File02": a page with a folded corner and two lines.
    static let file = SVGIcon(viewBox: 24, style: .stroke(width: 1.8), paths: [
        "M8 17H16",
        "M8 13H12",
        "M13 2.5V3C13 5.82843 13 7.24264 13.8787 8.12132C14.7574 9 16.1716 9 19 9H19.5M20 10.6569V14C20 17.7712 20 19.6569 18.8284 20.8284C17.6569 22 15.7712 22 12 22C8.22876 22 6.34315 22 5.17157 20.8284C4 19.6569 4 17.7712 4 14V9.45584C4 6.21082 4 4.58831 4.88607 3.48933C5.06508 3.26731 5.26731 3.06508 5.48933 2.88607C6.58831 2 8.21082 2 11.4558 2C12.1614 2 12.5141 2 12.8372 2.11401C12.9044 2.13772 12.9702 2.165 13.0345 2.19575C13.3436 2.34355 13.593 2.593 14.0919 3.09188L18.8284 7.82843C19.4065 8.40649 19.6955 8.69552 19.8478 9.06306C20 9.4306 20 9.83935 20 10.6569Z",
    ])

    /// Closed folder (an outlined shape pre-converted to a fill).
    static let folderClosed = SVGIcon(viewBox: 24, style: .fill, paths: [
        "M12 7L11.11 7.45C11.27 7.79 11.62 8 12 8V7ZM20.67 7.51L20.11 8.34L20.11 8.34L20.67 7.51ZM21.49 8.33L22.33 7.78L22.33 7.78L21.49 8.33ZM21.16 18.78L20.33 18.22L20.33 18.22L21.16 18.78ZM19.78 20.16L19.22 19.33L19.22 19.33L19.78 20.16ZM3.46 19.54L4.17 18.83L4.17 18.83L3.46 19.54ZM2.38 4.54L3.25 5.03L3.25 5.03L2.38 4.54ZM3.54 3.38L4.03 4.25L4.03 4.25L3.54 3.38ZM9.2 3.19L9.55 2.25L9.55 2.25L9.2 3.19ZM11.37 5.73L12.26 5.29L12.26 5.29L11.37 5.73ZM12 7V8H16.75V7V6H12V7ZM16.75 7V8C17.82 8 18.55 8 19.11 8.06C19.66 8.11 19.92 8.21 20.11 8.34L20.67 7.51L21.22 6.67C20.65 6.29 20.02 6.14 19.32 6.07C18.63 6 17.78 6 16.75 6V7ZM20.67 7.51L20.11 8.34C20.33 8.48 20.52 8.67 20.66 8.89L21.49 8.33L22.33 7.78C22.03 7.34 21.66 6.97 21.22 6.67L20.67 7.51ZM21.49 8.33L20.66 8.89C20.79 9.08 20.89 9.34 20.94 9.89C21 10.45 21 11.18 21 12.25H22H23C23 11.22 23 10.37 22.93 9.68C22.86 8.98 22.71 8.35 22.33 7.78L21.49 8.33ZM22 12.25H21C21 14.03 21 15.28 20.9 16.26C20.8 17.21 20.62 17.78 20.33 18.22L21.16 18.78L21.99 19.33C22.54 18.51 22.78 17.57 22.89 16.46C23 15.36 23 13.98 23 12.25H22ZM21.16 18.78L20.33 18.22C20.03 18.66 19.66 19.03 19.22 19.33L19.78 20.16L20.33 20.99C20.99 20.55 21.55 19.99 21.99 19.33L21.16 18.78ZM19.78 20.16L19.22 19.33C18.78 19.62 18.21 19.8 17.26 19.9C16.28 20 15.03 20 13.25 20V21V22C14.98 22 16.36 22 17.46 21.89C18.57 21.78 19.51 21.54 20.33 20.99L19.78 20.16ZM13.25 21V20H12V21V22H13.25V21ZM12 21V20C9.61 20 7.93 20 6.65 19.83C5.4 19.66 4.69 19.34 4.17 18.83L3.46 19.54L2.76 20.24C3.71 21.19 4.91 21.61 6.38 21.81C7.82 22 9.67 22 12 22V21ZM3.46 19.54L4.17 18.83C3.66 18.31 3.34 17.6 3.17 16.35C3 15.07 3 13.39 3 11H2H1C1 13.33 1 15.18 1.19 16.62C1.39 18.09 1.81 19.29 2.76 20.24L3.46 19.54ZM2 11H3V7.94H2H1V11H2ZM2 7.94H3C3 7.02 3 6.39 3.04 5.9C3.09 5.43 3.16 5.19 3.25 5.03L2.38 4.54L1.51 4.05C1.22 4.57 1.1 5.12 1.05 5.73C1 6.32 1 7.05 1 7.94H2ZM2.38 4.54L3.25 5.03C3.43 4.7 3.7 4.43 4.03 4.25L3.54 3.38L3.05 2.51C2.4 2.87 1.87 3.4 1.51 4.05L2.38 4.54ZM3.54 3.38L4.03 4.25C4.19 4.16 4.43 4.09 4.9 4.04C5.39 4 6.02 4 6.94 4V3V2C6.05 2 5.32 2 4.73 2.05C4.12 2.1 3.57 2.22 3.05 2.51L3.54 3.38ZM6.94 3V4C8.19 4 8.55 4.02 8.85 4.13L9.2 3.19L9.55 2.25C8.83 1.98 8.03 2 6.94 2V3ZM9.2 3.19L8.85 4.13C9.57 4.4 9.9 5.03 10.47 6.18L11.37 5.73L12.26 5.29C11.79 4.34 11.15 2.85 9.55 2.25L9.2 3.19ZM11.37 5.73L10.47 6.18L11.11 7.45L12 7L12.89 6.55L12.26 5.29L11.37 5.73Z",
    ])

    /// Open folder: back panel plus a tilted front flap.
    static let folderOpen = SVGIcon(viewBox: 24, style: .stroke(width: 2), paths: [
        "M2 18V7.55C2 7.13 2 6.58 2 6C2 4.34 3.34 3 5 3L8.15 3C9.28 3 10.32 3.64 10.83 4.66L12 7H16C17.4 7 18.1 7 18.64 7.27C19.11 7.51 19.49 7.89 19.73 8.37C20 8.9 20 9.6 20 11C20 12.4 20 11.08 20 11.08",
        "M5.02 13.15C5.59 12.43 6.46 12 7.39 12H20.26C21.86 12 22.81 13.78 21.92 15.11L19.46 18.78C18.54 20.17 16.98 21 15.31 21H5.05C2.55 21 1.15 18.12 2.68 16.15L5.02 13.15Z",
    ])

    /// Hugeicons "ArrowRight01": the disclosure chevron a hovered folder shows.
    static let chevron = SVGIcon(viewBox: 24, style: .stroke(width: 2), paths: [
        "M9.00005 6C9.00005 6 15 10.4189 15 12C15 13.5812 9 18 9 18",
    ])

    /// Hugeicons "Search01".
    static let search = SVGIcon(viewBox: 24, style: .stroke(width: 2), paths: [
        "M17 17L21 21",
        "M19 11C19 6.58172 15.4183 3 11 3C6.58172 3 3 6.58172 3 11C3 15.4183 6.58172 19 11 19C15.4183 19 19 15.4183 19 11Z",
    ])

    /// Hugeicons "SidebarLeft": the toggle in the window chrome.
    static let sidebarLeft = SVGIcon(viewBox: 24, style: .stroke(width: 2), paths: [
        "M2 12C2 8.31087 2 6.4663 2.81382 5.15877C3.1149 4.67502 3.48891 4.25427 3.91891 3.91554C5.08116 3 6.72077 3 10 3H14C17.2792 3 18.9188 3 20.0811 3.91554C20.5111 4.25427 20.8851 4.67502 21.1862 5.15877C22 6.4663 22 8.31087 22 12C22 15.6891 22 17.5337 21.1862 18.8412C20.8851 19.325 20.5111 19.7457 20.0811 20.0845C18.9188 21 17.2792 21 14 21H10C6.72077 21 5.08116 21 3.91891 20.0845C3.48891 19.7457 3.1149 19.325 2.81382 18.8412C2 17.5337 2 15.6891 2 12Z",
        "M9.5 3L9.5 21",
        "M5 7H6M5 10H6",
    ])

    /// Up/down chevrons on the workspace switcher.
    static let switcher = SVGIcon(viewBox: 16, style: .fill, paths: [
        "M8.71 2.4C8.32 2.01 7.68 2.01 7.29 2.4L4.47 5.22L3.94 5.75L5 6.81L5.53 6.28L8 3.81L10.47 6.28L11 6.81L12.06 5.75L11.53 5.22L8.71 2.4ZM5.53 9.72L5 9.19L3.94 10.25L4.47 10.78L7.29 13.6C7.68 13.99 8.32 13.99 8.71 13.6L11.53 10.78L12.06 10.25L11 9.19L10.47 9.72L8 12.19L5.53 9.72Z",
    ])

    /// Three dots on the "Show More" row.
    static let ellipsis = SVGIcon(viewBox: 24, style: .stroke(width: 2.4), paths: [
        "M7 12H7.01M12 12H12.01M17 12H17.01",
    ])

    /// The small caret next to a section title.
    static let caret = SVGIcon(viewBox: 12, style: .stroke(width: 1.6), paths: [
        "M4.5 3.5L7.5 6L4.5 8.5",
    ])
}

/// One icon: path data on a square grid plus how to paint it.
struct SVGIcon {
    enum Style {
        case fill
        case stroke(width: CGFloat)
    }

    let viewBox: CGFloat
    let style: Style
    let paths: [String]

    /// The icon drawn in `currentColor` at `size` points.
    func view(size: CGFloat) -> some View {
        SVGIconView(icon: self, size: size)
    }
}

private struct SVGIconView: View {
    let icon: SVGIcon
    let size: CGFloat

    var body: some View {
        let shape = SVGShape(icon: icon)
        Group {
            switch icon.style {
            case .fill:
                shape.fill(style: FillStyle(eoFill: false))
            case .stroke(let width):
                shape.stroke(style: StrokeStyle(
                    lineWidth: width * size / icon.viewBox,
                    lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SVGShape: Shape {
    let icon: SVGIcon

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for data in icon.paths {
            path.addPath(SVGPathParser.parse(data))
        }
        let scale = min(rect.width, rect.height) / icon.viewBox
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// Minimal SVG path-data parser: M/L/H/V/C/Z and their relative forms, which
/// is all the bundled icons use.
enum SVGPathParser {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character = "M"
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        let scalars = Array(data.unicodeScalars)
        var index = 0

        func flush() {
            guard !numbers.isEmpty || command == "Z" || command == "z" else { return }
            apply(command, numbers, &path, &current, &subpathStart)
            numbers.removeAll()
        }

        while index < scalars.count {
            let ch = Character(scalars[index])
            if ch.isLetter {
                flush()
                command = ch
                if ch == "Z" || ch == "z" {
                    apply(ch, [], &path, &current, &subpathStart)
                    command = "L" // stray coordinates after Z continue the path
                }
                index += 1
            } else if ch == "-" || ch == "." || ch.isNumber {
                var end = index
                var seenDot = false
                var seenExponent = false
                while end < scalars.count {
                    let c = Character(scalars[end])
                    if c.isNumber { end += 1; continue }
                    if c == "." && !seenDot && !seenExponent { seenDot = true; end += 1; continue }
                    if (c == "e" || c == "E") && !seenExponent {
                        seenExponent = true; end += 1
                        if end < scalars.count, Character(scalars[end]) == "-" { end += 1 }
                        continue
                    }
                    if c == "-" && end == index { end += 1; continue }
                    break
                }
                let text = String(String.UnicodeScalarView(scalars[index..<end]))
                if let value = Double(text) { numbers.append(CGFloat(value)) }
                index = max(end, index + 1)
            } else {
                index += 1
            }
        }
        flush()
        return path
    }

    private static func apply(_ command: Character, _ n: [CGFloat], _ path: inout Path,
                              _ current: inout CGPoint, _ start: inout CGPoint) {
        let relative = command.isLowercase
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }
        switch command.uppercased() {
        case "M":
            var i = 0
            while i + 1 < n.count {
                let p = point(n[i], n[i + 1])
                if i == 0 { path.move(to: p); start = p } else { path.addLine(to: p) }
                current = p
                i += 2
            }
        case "L":
            var i = 0
            while i + 1 < n.count {
                let p = point(n[i], n[i + 1])
                path.addLine(to: p)
                current = p
                i += 2
            }
        case "H":
            for x in n {
                let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: p)
                current = p
            }
        case "V":
            for y in n {
                let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: p)
                current = p
            }
        case "C":
            var i = 0
            while i + 5 < n.count {
                let c1 = point(n[i], n[i + 1])
                let c2 = point(n[i + 2], n[i + 3])
                let p = point(n[i + 4], n[i + 5])
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                i += 6
            }
        case "Z":
            path.closeSubpath()
            current = start
        default:
            break
        }
    }
}
