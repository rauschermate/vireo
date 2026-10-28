import { Menu, MenuItem, PredefinedMenuItem, Submenu } from "@tauri-apps/api/menu";
import { accelString, Command, commandById, isEnabled, labelOf, runCommand } from "./commands";
import { basename } from "./paths";
import type { Store } from "./store";

// The native menu bar, built from the command registry. It is rebuilt when a
// label, an enabled state, the tab list or the recent files change.

type Entry = string | "-" | { submenu: string; items: Entry[] } | { predefined: Parameters<typeof PredefinedMenuItem.new>[0] } | { recent: true };

const layout: { title: string; items: Entry[]; windows?: boolean }[] = [
  {
    title: "Vireo",
    items: [{ predefined: { item: { About: null } } }, "-", "app.settings", "-", { predefined: { item: "Services" } }, "-", { predefined: { item: "Hide" } }, { predefined: { item: "HideOthers" } }, { predefined: { item: "ShowAll" } }, "-", "app.quit"],
  },
  {
    title: "File",
    items: ["file.newFile", "file.newTab", "file.open", "file.openFolder", { recent: true }, "file.quickOpen", "file.closeWorkspace", "-", "file.save", "file.saveAs", "-", "file.closeTab"],
  },
  {
    title: "Edit",
    items: ["edit.undo", "edit.redo", "-", { predefined: { item: "Cut" } }, { predefined: { item: "Copy" } }, { predefined: { item: "Paste" } }, { predefined: { item: "SelectAll" } }, "-", "edit.find"],
  },
  { title: "Insert", items: ["insert.table", "insert.codeBlock", "insert.image", "insert.task", "insert.rule"] },
  {
    title: "Format",
    items: ["format.bold", "format.italic", "format.strike", "format.code", "-", "format.h1", "format.h2", "format.h3", "-", "format.list", "format.quote", "-", "format.link"],
  },
  {
    title: "View",
    items: ["view.sidebar", "view.toc", "view.focus", "-", "view.zoomIn", "view.zoomOut", "view.zoomReset", "-", { predefined: { item: "Fullscreen" } }],
  },
  {
    title: "Window",
    windows: true,
    items: [{ predefined: { item: "Minimize" } }, { predefined: { item: "Maximize" } }, "-", "tab.1", "tab.2", "tab.3", "tab.4", "tab.5", "tab.6", "tab.7", "tab.8", "tab.last", "-", { predefined: { item: "BringAllToFront" } }],
  },
];

function signature(s: Store): string {
  const parts: string[] = [];
  for (const c of commandById.values()) parts.push(`${labelOf(c, s)}:${isEnabled(c, s)}`);
  parts.push(s.prefs.recentFiles.join("|"));
  return parts.join(";");
}

async function item(s: Store, c: Command) {
  return MenuItem.new({
    id: c.id,
    text: labelOf(c, s),
    accelerator: c.accel ? accelString(c.accel) : undefined,
    enabled: isEnabled(c, s),
    action: () => runCommand(s, c.id, "menu"),
  });
}

async function build(s: Store, entries: Entry[]): Promise<(MenuItem | PredefinedMenuItem | Submenu)[]> {
  const out: (MenuItem | PredefinedMenuItem | Submenu)[] = [];
  for (const e of entries) {
    if (e === "-") out.push(await PredefinedMenuItem.new({ item: "Separator" }));
    else if (typeof e === "string") {
      const c = commandById.get(e);
      // Tab items exist only for open tabs.
      if (c && !(e.startsWith("tab.") && e !== "tab.last" && !c.enabled?.(s))) out.push(await item(s, c));
    } else if ("predefined" in e) out.push(await PredefinedMenuItem.new(e.predefined));
    else if ("recent" in e) {
      const recents = await Promise.all(
        s.prefs.recentFiles.map((path) => MenuItem.new({ text: basename(path), action: () => void s.openPath(path) })),
      );
      out.push(await Submenu.new({ text: "Open Recent", items: recents, enabled: recents.length > 0 }));
    } else out.push(await Submenu.new({ text: e.submenu, items: await build(s, e.items) }));
  }
  return out;
}

export function installMenu(s: Store) {
  let current = "";
  let timer = 0;
  let building = false;
  const rebuild = async () => {
    const sig = signature(s);
    if (sig === current || building) return;
    building = true;
    current = sig;
    const submenus: Submenu[] = [];
    for (const m of layout) {
      const sub = await Submenu.new({ text: m.title, items: await build(s, m.items) });
      if (m.windows) await sub.setAsWindowsMenuForNSApp();
      submenus.push(sub);
    }
    const menu = await Menu.new({ items: submenus });
    await menu.setAsAppMenu();
    building = false;
    if (signature(s) !== current) void rebuild();
  };
  s.subscribe(() => {
    clearTimeout(timer);
    timer = window.setTimeout(() => void rebuild(), 120);
  });
  // Enabled states depend on which editor holds focus.
  document.addEventListener("focusin", () => {
    clearTimeout(timer);
    timer = window.setTimeout(() => void rebuild(), 120);
  });
  void rebuild();
}
