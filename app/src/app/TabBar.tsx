import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { Doc } from "./store";
import { Icon, InlineEdit, showContextMenu, useStore } from "./ui";

// Vireo's tab metrics.
const MIN_TAB = 72;
const ACTIVE_MIN_TAB = 96;
const MAX_TAB = 200;
const GAP = 3;

function tabWidths(count: number, activeIndex: number, available: number): number[] {
  if (count === 0) return [];
  const even = (available - GAP * (count - 1)) / count;
  if (even >= ACTIVE_MIN_TAB) return Array(count).fill(Math.min(MAX_TAB, even));
  // Below the active floor, the active tab keeps 96 and the others share the rest.
  const rest = count > 1 ? (available - GAP * (count - 1) - ACTIVE_MIN_TAB) / (count - 1) : 0;
  return Array.from({ length: count }, (_, i) => (i === activeIndex ? ACTIVE_MIN_TAB : Math.max(MIN_TAB, rest)));
}

async function toggleFullscreen() {
  if (!("__TAURI_INTERNALS__" in window)) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  const win = getCurrentWindow();
  await win.setFullscreen(!(await win.isFullscreen()));
}

export function TabBar() {
  const s = useStore();
  const strip = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(600);
  useLayoutEffect(() => {
    const el = strip.current!;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    setWidth(el.clientWidth);
    return () => ro.disconnect();
  }, []);
  const activeIndex = s.docs.findIndex((d) => d.id === s.activeId);
  const widths = tabWidths(s.docs.length, activeIndex, width - 4);

  // Keep the active tab in view when the strip scrolls.
  useEffect(() => {
    strip.current?.querySelector(".vr-tab.is-active")?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [s.activeId, s.docs.length]);

  const menu = (e: React.MouseEvent, doc: Doc, index: number) =>
    showContextMenu(e, [
      { label: "Rename…", run: () => ((s.ui.renaming = `tab:${doc.id}`), s.emit()) },
      "-",
      { label: "Close Tab", run: () => void s.closeTab(doc.id) },
      { label: "Close Other Tabs", run: () => void s.closeOthers(doc.id), enabled: s.docs.length > 1 },
      { label: "Close Tabs to the Right", run: () => void s.closeRight(doc.id), enabled: index < s.docs.length - 1 },
      ...(doc.path
        ? (["-", { label: "Reveal in Sidebar", run: () => revealInSidebar(doc.path!) }, { label: "Copy Path", run: () => void navigator.clipboard.writeText(doc.path!) }] as const)
        : []),
    ]);

  const revealInSidebar = (path: string) => {
    const root = s.workspace.root;
    if (!root || !path.startsWith(root + "/")) return;
    let dir = path.slice(0, path.lastIndexOf("/"));
    while (dir.length > root.length) {
      s.ui.expanded.add(dir);
      dir = dir.slice(0, dir.lastIndexOf("/"));
    }
    s.ui.selection = new Set([path]);
    s.ui.everythingCollapsed = false;
    if (!s.prefs.sidebarVisible) s.setPref("sidebarVisible", true);
    s.emit();
    requestAnimationFrame(() => document.querySelector(`[data-path="${CSS.escape(path)}"]`)?.scrollIntoView({ block: "nearest" }));
  };

  return (
    <div className="vr-tabbar" data-tauri-drag-region>
      <div className="vr-tabs" ref={strip} data-tauri-drag-region role="tablist">
        {s.docs.map((doc, i) => {
          const active = doc.id === s.activeId;
          const renaming = s.ui.renaming === `tab:${doc.id}`;
          const warn = doc.saveError || doc.conflict;
          return (
            <div
              key={doc.id}
              role="tab"
              aria-selected={active}
              className={"vr-tab" + (active ? " is-active" : "") + (doc.dirty ? " is-dirty" : "")}
              style={{ width: widths[i] }}
              title={s.title(doc)}
              onMouseDown={(e) => {
                if (e.button === 0) s.activate(doc.id);
              }}
              onMouseUp={(e) => {
                if (e.button === 1) void s.closeTab(doc.id);
              }}
              onDoubleClick={() => void toggleFullscreen()}
              onContextMenu={(e) => menu(e, doc, i)}
            >
              {renaming ? (
                <InlineEdit
                  value={doc.path ? (doc.path.slice(doc.path.lastIndexOf("/") + 1)) : s.title(doc)}
                  selectStem
                  onCommit={(v) => {
                    s.ui.renaming = null;
                    s.emit();
                    void s.renameDoc(doc, v);
                  }}
                  onCancel={() => ((s.ui.renaming = null), s.emit())}
                />
              ) : (
                <span className="vr-tab-title">{s.title(doc)}</span>
              )}
              {warn && (
                <span className="vr-tab-warn" title={doc.conflict ? "Changed on disk" : (doc.saveError ?? "")}>
                  <Icon name="warning" />
                </span>
              )}
              <button
                type="button"
                className="vr-tab-close"
                aria-label="Close tab"
                onMouseDown={(e) => e.stopPropagation()}
                onClick={() => void s.closeTab(doc.id)}
              >
                <Icon name="close" />
              </button>
            </div>
          );
        })}
        <button type="button" className="vr-chrome-button vr-new-tab" title="New tab (⌘T)" aria-label="New tab" onClick={() => s.newTab()}>
          <Icon name="plus" />
        </button>
      </div>
      <button type="button" className="vr-chrome-button vr-tab-overflow" title="Search tabs" aria-label="Search tabs" onClick={() => s.toggle("tabSearch")}>
        <Icon name="chevronDown" />
      </button>
      {s.ui.tabSearch && <TabSearch />}
    </div>
  );
}

function TabSearch() {
  const s = useStore();
  const [query, setQuery] = useState("");
  const ref = useRef<HTMLDivElement>(null);
  const matches = s.docs.filter((d) => s.title(d).toLowerCase().includes(query.trim().toLowerCase()));
  useEffect(() => {
    const close = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node) && !(e.target as Element).closest?.(".vr-tab-overflow")) {
        s.ui.tabSearch = false;
        s.emit();
      }
    };
    addEventListener("mousedown", close, true);
    return () => removeEventListener("mousedown", close, true);
  }, []);
  const pick = (doc: Doc) => {
    s.ui.tabSearch = false;
    s.activate(doc.id);
    s.focusEditor();
  };
  return (
    <div className="vr-popover vr-tab-search" ref={ref}>
      <input
        autoFocus
        placeholder="Search tabs"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && matches[0]) pick(matches[0]);
          if (e.key === "Escape") {
            s.ui.tabSearch = false;
            s.emit();
          }
        }}
      />
      <div className="vr-tab-search-list">
        {matches.length === 0 && <div className="vr-empty">No matching tabs</div>}
        {matches.map((doc) => (
          <button type="button" key={doc.id} className="vr-row" onClick={() => pick(doc)}>
            <span className="vr-row-label">{s.title(doc)}</span>
            {(doc.saveError || doc.conflict) && <Icon name="warning" />}
            {doc.id === s.activeId && <span className="vr-check">✓</span>}
          </button>
        ))}
      </div>
    </div>
  );
}
