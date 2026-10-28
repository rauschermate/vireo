import type { Node } from "./backend";
import { basename, dirname, isMarkdown, stem } from "./paths";
import { SIDEBAR_MAX, SIDEBAR_MIN } from "./prefs";
import type { Store } from "./store";
import { Icon, InlineEdit, MenuItem, showContextMenu, useStore } from "./ui";

const PINNED_PAGE = 6;
const RECENTS_MIN_FILES = 10;
const RECENTS_COLLAPSED = 3;
const INDENT = 12;

export function Sidebar() {
  const s = useStore();
  const root = s.workspace.root;
  const resize = useResize(s);

  return (
    <aside className="vr-sidebar" style={{ width: s.prefs.sidebarWidth }} onContextMenu={(e) => root && rootMenu(s, e)}>
      <div className="vr-sidebar-top" data-tauri-drag-region>
        <SidebarToggle />
      </div>
      {!root ? (
        <div className="vr-sidebar-empty">
          <p>No folder open</p>
          <button type="button" className="vr-link-button" onClick={() => void s.promptOpenFolder()}>
            Open Folder…
          </button>
        </div>
      ) : (
        <>
          {s.prefs.showSearch && (
            <div className="vr-sidebar-search">
              <input
                type="search"
                placeholder="Search"
                value={s.ui.sidebarQuery}
                onChange={(e) => ((s.ui.sidebarQuery = e.target.value), s.emit())}
                onKeyDown={(e) => {
                  if (e.key === "Escape") ((s.ui.sidebarQuery = ""), s.emit());
                }}
              />
            </div>
          )}
          <div className="vr-sidebar-scroll" onDragOver={(e) => dragOver(e)} onDrop={(e) => drop(s, e, root)}>
            {s.ui.sidebarQuery.trim() ? <SearchResults /> : <Sections />}
          </div>
        </>
      )}
      <div className="vr-sidebar-resize" onMouseDown={resize} />
    </aside>
  );
}

export function SidebarToggle() {
  const s = useStore();
  return (
    <button
      type="button"
      className="vr-chrome-button vr-sidebar-toggle"
      title={s.prefs.sidebarVisible ? "Hide sidebar (⌘\\)" : "Show sidebar (⌘\\)"}
      aria-label="Toggle sidebar"
      onClick={() => s.setPref("sidebarVisible", !s.prefs.sidebarVisible)}
    >
      <Icon name="sidebar" />
    </button>
  );
}

function useResize(s: Store) {
  return (e: React.MouseEvent) => {
    e.preventDefault();
    const startX = e.clientX;
    const start = s.prefs.sidebarWidth;
    const max = () => Math.min(SIDEBAR_MAX, innerWidth * 0.35);
    const move = (m: MouseEvent) => {
      s.prefs.sidebarWidth = Math.round(Math.min(max(), Math.max(SIDEBAR_MIN, start + m.clientX - startX)));
      s.emit();
    };
    const up = () => {
      removeEventListener("mousemove", move);
      removeEventListener("mouseup", up);
      document.body.classList.remove("is-resizing");
      s.savePrefs();
    };
    document.body.classList.add("is-resizing");
    addEventListener("mousemove", move);
    addEventListener("mouseup", up);
  };
}

function Sections() {
  const s = useStore();
  const files = s.files();
  const byPath = new Map(files.map((f) => [f.path, f]));
  const pinned = s.pinned;
  const recents = files
    .filter((f) => !pinned.includes(f.path))
    .sort((a, b) => b.mtime - a.mtime || a.path.localeCompare(b.path));
  const showRecents = s.prefs.showRecents && files.length >= RECENTS_MIN_FILES;

  return (
    <>
      {pinned.length > 0 && (
        <section className="vr-section">
          <h3>Pinned</h3>
          {pinned.slice(0, s.ui.pinnedShown).map((path) => (
            <FileRow key={path} path={path} node={byPath.get(path) ?? null} depth={0} flat />
          ))}
          {pinned.length > s.ui.pinnedShown && (
            <button type="button" className="vr-more" onClick={() => ((s.ui.pinnedShown += PINNED_PAGE), s.emit())}>
              Show More
            </button>
          )}
        </section>
      )}
      {showRecents && (
        <section className="vr-section">
          <h3>Recents</h3>
          <div className={s.ui.recentsExpanded ? "vr-recents is-expanded" : "vr-recents"}>
            {(s.ui.recentsExpanded ? recents : recents.slice(0, RECENTS_COLLAPSED)).map((f) => (
              <FileRow key={f.path} path={f.path} node={f} depth={0} flat />
            ))}
          </div>
          {recents.length > RECENTS_COLLAPSED && (
            <button type="button" className="vr-more" onClick={() => ((s.ui.recentsExpanded = !s.ui.recentsExpanded), s.emit())}>
              {s.ui.recentsExpanded ? "Show Less" : "Show More"}
            </button>
          )}
        </section>
      )}
      <section className="vr-section">
        <h3 className="vr-section-toggle" onClick={() => ((s.ui.everythingCollapsed = !s.ui.everythingCollapsed), s.emit())}>
          <span className={s.ui.everythingCollapsed ? "vr-disclosure" : "vr-disclosure is-open"}>
            <Icon name="chevron" />
          </span>
          Everything
        </h3>
        {!s.ui.everythingCollapsed && <Tree />}
      </section>
    </>
  );
}

function Tree() {
  const s = useStore();
  if (s.workspace.status === "loading") return <div className="vr-empty">Loading…</div>;
  if (s.workspace.status === "error")
    return (
      <div className="vr-empty">
        <p>Couldn't load folder</p>
        <p className="vr-error">{s.workspace.error}</p>
        <button type="button" className="vr-link-button" onClick={() => void s.rescan()}>
          Try Again
        </button>
      </div>
    );
  if (s.workspace.tree.length === 0 && !s.ui.renaming) return <div className="vr-empty">No files</div>;
  return (
    <div role="tree">
      {s.workspace.tree.map((n) => (
        <TreeNode key={n.path} node={n} depth={0} />
      ))}
    </div>
  );
}

function TreeNode({ node, depth }: { node: Node; depth: number }) {
  const s = useStore();
  if (!node.dir) return <FileRow path={node.path} node={node} depth={depth} />;
  const open = s.ui.expanded.has(node.path);
  return (
    <>
      <Row node={node} path={node.path} depth={depth} open={open} />
      {open && node.children.map((c) => <TreeNode key={c.path} node={c} depth={depth + 1} />)}
    </>
  );
}

function FileRow({ path, node, depth, flat }: { path: string; node: Node | null; depth: number; flat?: boolean }) {
  return <Row node={node} path={path} depth={depth} flat={flat} />;
}

// The rows in visual order, for shift-click ranges.
function visiblePaths(s: Store): string[] {
  const out: string[] = [];
  const walk = (nodes: Node[]) => {
    for (const n of nodes) {
      out.push(n.path);
      if (n.dir && s.ui.expanded.has(n.path)) walk(n.children);
    }
  };
  walk(s.workspace.tree);
  return out;
}

let anchorPath: string | null = null;

function Row({ node, path, depth, open, flat }: { node: Node | null; path: string; depth: number; open?: boolean; flat?: boolean }) {
  const s = useStore();
  const dir = node?.dir ?? false;
  const selected = s.ui.selection.has(path);
  const activePath = s.active?.path;
  const label = node ? s.label(node) : isMarkdown(path) ? stem(basename(path)) : basename(path);
  const renaming = s.ui.renaming === path && !flat;

  const click = (e: React.MouseEvent) => {
    if (e.metaKey) {
      const next = new Set(s.ui.selection);
      next.has(path) ? next.delete(path) : next.add(path);
      s.ui.selection = next;
      anchorPath = path;
      return s.emit();
    }
    if (e.shiftKey && anchorPath && !flat) {
      const order = visiblePaths(s);
      const [a, b] = [order.indexOf(anchorPath), order.indexOf(path)].sort((x, y) => x - y);
      if (a >= 0) s.ui.selection = new Set(order.slice(a, b + 1));
      return s.emit();
    }
    anchorPath = path;
    s.ui.selection = new Set([path]);
    if (dir) {
      s.ui.expanded.has(path) ? s.ui.expanded.delete(path) : s.ui.expanded.add(path);
      s.emit();
    } else {
      s.emit();
      void s.openPath(path);
    }
  };

  return (
    <div
      className={"vr-row vr-tree-row" + (selected ? " is-selected" : "") + (!dir && activePath === path ? " is-current" : "")}
      style={{ paddingLeft: 10 + depth * INDENT }}
      data-path={path}
      role="treeitem"
      aria-expanded={dir ? !!open : undefined}
      draggable={!renaming}
      onClick={click}
      onContextMenu={(e) => {
        e.stopPropagation();
        if (!s.ui.selection.has(path)) {
          s.ui.selection = new Set([path]);
          s.emit();
        }
        rowMenu(s, e, node, path);
      }}
      onDragStart={(e) => {
        const paths = s.ui.selection.has(path) ? [...s.ui.selection] : [path];
        e.dataTransfer.setData("application/x-vireo-paths", JSON.stringify(paths));
        e.dataTransfer.effectAllowed = "move";
      }}
      onDragOver={(e) => dir && dragOver(e)}
      onDragEnter={(e) => dir && e.currentTarget.classList.add("is-drop")}
      onDragLeave={(e) => e.currentTarget.classList.remove("is-drop")}
      onDrop={(e) => {
        e.currentTarget.classList.remove("is-drop");
        if (dir) drop(s, e, path);
      }}
    >
      {dir ? (
        <span className={open ? "vr-disclosure is-open" : "vr-disclosure"}>
          <Icon name="chevron" />
        </span>
      ) : (
        <span className="vr-disclosure" />
      )}
      {renaming ? (
        <InlineEdit
          value={node?.name ?? basename(path)}
          selectStem={!dir}
          onCommit={(v) => {
            s.ui.renaming = null;
            s.emit();
            if (v.trim() && v.trim() !== (node?.name ?? basename(path))) void s.renamePath(path, v, dir);
          }}
          onCancel={() => ((s.ui.renaming = null), s.emit())}
        />
      ) : (
        <span className="vr-row-label" title={flat ? s.relativePath(path) : undefined}>
          {label}
        </span>
      )}
    </div>
  );
}

function dragOver(e: React.DragEvent) {
  if (!e.dataTransfer.types.includes("application/x-vireo-paths")) return;
  e.preventDefault();
  e.stopPropagation();
  e.dataTransfer.dropEffect = "move";
}

function drop(s: Store, e: React.DragEvent, dir: string) {
  const raw = e.dataTransfer.getData("application/x-vireo-paths");
  if (!raw) return;
  e.preventDefault();
  e.stopPropagation();
  void s.moveInto(JSON.parse(raw), dir);
}

function copyPaths(s: Store, paths: string[], relative: boolean) {
  void navigator.clipboard.writeText(paths.map((p) => (relative ? s.relativePath(p) : p)).join("\n"));
}

function rowMenu(s: Store, e: React.MouseEvent, node: Node | null, path: string) {
  const selection = [...s.ui.selection];
  if (selection.length > 1) {
    return showContextMenu(e, [
      { label: `Copy ${selection.length} relative paths`, run: () => copyPaths(s, selection, true) },
      { label: `Copy ${selection.length} absolute paths`, run: () => copyPaths(s, selection, false) },
      "-",
      { label: `Delete ${selection.length} items`, run: () => void s.deletePaths(selection), danger: true },
    ]);
  }
  const rename = () => {
    s.ui.renaming = path;
    s.emit();
  };
  if (node?.dir) {
    return showContextMenu(e, [
      { label: "New File", run: () => void s.createFileIn(path) },
      { label: "New Folder", run: () => void s.createFolderIn(path) },
      "-",
      { label: "Copy relative path", run: () => copyPaths(s, [path], true) },
      { label: "Copy absolute path", run: () => copyPaths(s, [path], false) },
      "-",
      { label: "Open in Terminal", run: () => void s.backend.openInTerminal(path) },
      { label: "Reveal in Finder", run: () => void s.backend.reveal(path) },
      "-",
      { label: "Rename...", run: rename },
      { label: "Delete", run: () => void s.deletePaths([path]), danger: true },
    ]);
  }
  const pinned = s.pinned.includes(path);
  const items: MenuItem[] = [
    { label: "Open", run: () => void s.openPath(path) },
    { label: pinned ? "Unpin" : "Pin", run: () => s.togglePin(path) },
    { label: "Duplicate", run: () => void s.duplicate(path) },
    "-",
    { label: "Copy relative path", run: () => copyPaths(s, [path], true) },
    { label: "Copy absolute path", run: () => copyPaths(s, [path], false) },
    { label: "Reveal in Finder", run: () => void s.backend.reveal(path) },
    "-",
    { label: "Rename...", run: rename },
    { label: "Delete", run: () => void s.deletePaths([path]), danger: true },
  ];
  showContextMenu(e, items);
}

function rootMenu(s: Store, e: React.MouseEvent) {
  const root = s.workspace.root!;
  showContextMenu(e, [
    { label: "New File", run: () => void s.createFileIn(root) },
    { label: "New Folder", run: () => void s.createFolderIn(root) },
    "-",
    { label: "Open in Terminal", run: () => void s.backend.openInTerminal(root) },
    { label: "Open in Finder", run: () => void s.backend.openExternal(root) },
    "-",
    { label: "Search", checked: s.prefs.showSearch, run: () => s.setPref("showSearch", !s.prefs.showSearch) },
    { label: "Recents", checked: s.prefs.showRecents, run: () => s.setPref("showRecents", !s.prefs.showRecents) },
  ]);
}

function SearchResults() {
  const s = useStore();
  const q = s.ui.sidebarQuery.trim().toLowerCase();
  const hits = s.files().filter((f) => s.label(f).toLowerCase().includes(q) || f.name.toLowerCase().includes(q));
  if (hits.length === 0) return <div className="vr-empty">No results</div>;
  return (
    <section className="vr-section">
      {hits.map((f) => (
        <div key={f.path} className={"vr-row vr-tree-row vr-search-hit" + (s.active?.path === f.path ? " is-current" : "")} onClick={() => void s.openPath(f.path)} data-path={f.path}>
          <span className="vr-disclosure" />
          <span className="vr-row-label">{s.label(f)}</span>
          <span className="vr-row-detail">{relativeDir(s, f.path)}</span>
        </div>
      ))}
    </section>
  );
}

function relativeDir(s: Store, path: string): string {
  const rel = s.relativePath(path);
  return rel.includes("/") ? rel.slice(0, rel.lastIndexOf("/")) : "";
}
