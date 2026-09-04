import Foundation
import SwiftUI
import XCTest
import VireoCore
@testable import Vireo

final class SidebarTreeTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/ws")

    private func file(_ path: String) -> FileNode {
        let url = URL(fileURLWithPath: path)
        return FileNode(id: url, name: url.lastPathComponent, isDirectory: false, children: nil)
    }

    private func folder(_ path: String, _ children: [FileNode] = []) -> FileNode {
        let url = URL(fileURLWithPath: path)
        return FileNode(id: url, name: url.lastPathComponent, isDirectory: true,
                        children: children.isEmpty ? nil : children)
    }

    func testFlattenFollowsExpansion() {
        let tree = [
            folder("/ws/A", [file("/ws/A/a1.md"), folder("/ws/A/B", [file("/ws/A/B/b1.md")])]),
            file("/ws/z.md"),
        ]
        var closed: [FlatTreeItem] = []
        SidebarTree.flatten(tree, expanded: [], into: &closed)
        XCTAssertEqual(closed.map(\.node.name), ["A", "z.md"])

        var open: [FlatTreeItem] = []
        SidebarTree.flatten(tree, expanded: [URL(fileURLWithPath: "/ws/A")], into: &open)
        XCTAssertEqual(open.map(\.node.name), ["A", "a1.md", "B", "z.md"])
        XCTAssertEqual(open.map(\.depth), [0, 1, 1, 0])
    }

    func testResolveDropDir() {
        XCTAssertEqual(SidebarTree.resolveDropDir(target: nil, root: root).path, "/ws")
        XCTAssertEqual(SidebarTree.resolveDropDir(target: folder("/ws/A"), root: root).path, "/ws/A")
        XCTAssertEqual(SidebarTree.resolveDropDir(target: file("/ws/A/a.md"), root: root).path, "/ws/A")
    }

    func testCanMoveInto() {
        let a = URL(fileURLWithPath: "/ws/A")
        XCTAssertFalse(SidebarTree.canMoveInto(URL(fileURLWithPath: "/ws/A/a.md"), isDirectory: false, dest: a),
                       "already inside")
        XCTAssertTrue(SidebarTree.canMoveInto(URL(fileURLWithPath: "/ws/z.md"), isDirectory: false, dest: a))
        XCTAssertFalse(SidebarTree.canMoveInto(a, isDirectory: true, dest: a), "into itself")
        XCTAssertFalse(SidebarTree.canMoveInto(a, isDirectory: true, dest: URL(fileURLWithPath: "/ws/A/B")),
                       "into a descendant")
        XCTAssertFalse(SidebarTree.canMoveInto(a, isDirectory: true, dest: root), "already at root")
        XCTAssertTrue(SidebarTree.canMoveInto(a, isDirectory: true, dest: URL(fileURLWithPath: "/ws/C")))
        XCTAssertTrue(SidebarTree.canMoveInto(URL(fileURLWithPath: "/ws/AB"), isDirectory: true, dest: a),
                      "a sibling whose name shares a prefix is not a descendant")
    }

    func testResolveDropRangeCoversFolderAndVisibleDescendants() {
        let rows = [
            FlatTreeItem(node: folder("/ws/A"), depth: 0),
            FlatTreeItem(node: file("/ws/A/a1.md"), depth: 1),
            FlatTreeItem(node: folder("/ws/A/B"), depth: 1),
            FlatTreeItem(node: file("/ws/A/B/b1.md"), depth: 2),
            FlatTreeItem(node: file("/ws/z.md"), depth: 0),
        ]
        let a = SidebarTree.resolveDropRange(rows: rows, destDir: URL(fileURLWithPath: "/ws/A"), root: root)
        XCTAssertEqual(a?.start.path, "/ws/A")
        XCTAssertEqual(a?.end.path, "/ws/A/B/b1.md")

        let b = SidebarTree.resolveDropRange(rows: rows, destDir: URL(fileURLWithPath: "/ws/A/B"), root: root)
        XCTAssertEqual(b?.start.path, "/ws/A/B")
        XCTAssertEqual(b?.end.path, "/ws/A/B/b1.md")

        let whole = SidebarTree.resolveDropRange(rows: rows, destDir: root, root: root)
        XCTAssertEqual(whole?.start.path, "/ws/A")
        XCTAssertEqual(whole?.end.path, "/ws/z.md")

        XCTAssertNil(SidebarTree.resolveDropRange(rows: rows, destDir: URL(fileURLWithPath: "/ws/missing"), root: root))
    }

    func testRowAtYAttachesGapsToTheRowAbove() {
        let frames: [(id: URL, frame: CGRect)] = [
            (URL(fileURLWithPath: "/ws/a.md"), CGRect(x: 0, y: 0, width: 200, height: 32)),
            (URL(fileURLWithPath: "/ws/b.md"), CGRect(x: 0, y: 33, width: 200, height: 32)),
        ]
        XCTAssertNil(SidebarTree.rowAt(y: -1, frames: frames))
        XCTAssertEqual(SidebarTree.rowAt(y: 10, frames: frames)?.path, "/ws/a.md")
        XCTAssertEqual(SidebarTree.rowAt(y: 32.5, frames: frames)?.path, "/ws/a.md")
        XCTAssertEqual(SidebarTree.rowAt(y: 40, frames: frames)?.path, "/ws/b.md")
        XCTAssertEqual(SidebarTree.rowAt(y: 500, frames: frames)?.path, "/ws/b.md")
    }

    func testAncestorsBetweenRootAndLeaf() {
        let leaf = URL(fileURLWithPath: "/ws/A/B/c.md")
        XCTAssertEqual(SidebarTree.ancestors(of: leaf, below: root).map(\.path), ["/ws/A", "/ws/A/B"])
        XCTAssertEqual(SidebarTree.ancestors(of: URL(fileURLWithPath: "/ws/top.md"), below: root), [])
        XCTAssertEqual(SidebarTree.ancestors(of: URL(fileURLWithPath: "/elsewhere/x.md"), below: root), [])
    }

    @MainActor
    func testModelRewritesPathsAfterMove() {
        let model = SidebarModel()
        model.reset(for: root, pinned: [URL(fileURLWithPath: "/ws/A/a.md")])
        model.expand(URL(fileURLWithPath: "/ws/A"))
        model.expand(URL(fileURLWithPath: "/ws/A/B"))
        model.selection = [URL(fileURLWithPath: "/ws/A/a.md")]

        model.rewrite(from: URL(fileURLWithPath: "/ws/A"), to: URL(fileURLWithPath: "/ws/Renamed"))

        XCTAssertEqual(Set(model.expanded.map(\.path)), ["/ws/Renamed", "/ws/Renamed/B"])
        XCTAssertEqual(model.pinned.map(\.path), ["/ws/Renamed/a.md"])
        XCTAssertEqual(model.selection.map(\.path), ["/ws/Renamed/a.md"])

        model.forget(URL(fileURLWithPath: "/ws/Renamed"))
        XCTAssertTrue(model.expanded.isEmpty)
        XCTAssertTrue(model.pinned.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testSidebarWidthClamp() {
        XCTAssertEqual(SidebarMetrics.clampWidth(100, windowWidth: 1200), 220)
        XCTAssertEqual(SidebarMetrics.clampWidth(300.4, windowWidth: 1200), 300)
        XCTAssertEqual(SidebarMetrics.clampWidth(900, windowWidth: 1200), 420)
        XCTAssertEqual(SidebarMetrics.clampWidth(900, windowWidth: 600), 280, "narrow windows keep a floor")
    }

    func testSVGPathParserHandlesAbsoluteAndRelativeCommands() {
        let path = SVGPathParser.parse("M2 2H10V10H2Z")
        XCTAssertEqual(path.boundingRect, CGRect(x: 2, y: 2, width: 8, height: 8))

        let relative = SVGPathParser.parse("m1 1 l2 0 v2 h-2 z")
        XCTAssertEqual(relative.boundingRect, CGRect(x: 1, y: 1, width: 2, height: 2))

        let curve = SVGPathParser.parse("M0 0C0 10 10 10 10 0")
        XCTAssertEqual(curve.boundingRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(curve.boundingRect.maxX, 10, accuracy: 0.001)
        XCTAssertGreaterThan(curve.boundingRect.maxY, 5)

        // Numbers glued together with a minus sign, as exporters emit them.
        let glued = SVGPathParser.parse("M4-4L-4 4")
        XCTAssertEqual(glued.boundingRect, CGRect(x: -4, y: -4, width: 8, height: 8))
    }

    func testBundledIconsParseToNonEmptyPaths() {
        let icons: [SVGIcon] = [
            SidebarIcon.file, SidebarIcon.folderClosed, SidebarIcon.folderOpen, SidebarIcon.chevron,
            SidebarIcon.search, SidebarIcon.sidebarLeft, SidebarIcon.switcher, SidebarIcon.ellipsis,
            SidebarIcon.caret,
        ]
        for icon in icons {
            for data in icon.paths {
                let bounds = SVGPathParser.parse(data).boundingRect
                XCTAssertFalse(bounds.isNull, "empty path in \(data.prefix(20))")
                XCTAssertLessThanOrEqual(bounds.maxX, icon.viewBox + 0.5)
                XCTAssertLessThanOrEqual(bounds.maxY, icon.viewBox + 0.5)
            }
        }
    }
}
