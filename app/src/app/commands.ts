import { redo, undo } from "@codemirror/commands";
import { openSearchPanel } from "@codemirror/search";
import { StateCommand } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { makeHeading, toggleLinePrefix, wrapSelection } from "../editor/format";
import { insertCodeBlock, insertImage, insertRule, insertTable } from "../editor/insert";
import { openLinkEditor } from "../editor/toolbar";
import { basename, dirname, stem } from "./paths";
import type { Store } from "./store";

// One registry drives the native menu bar, the keyboard shortcuts, and the
// browser test mode.

export interface Accel {
  // A KeyboardEvent.code, which is also an accelerator key name in Tauri.
  code: string;
  shift?: boolean;
  alt?: boolean;
}

export interface Command {
  id: string;
  label: string | ((s: Store) => string);
  accel?: Accel;
  run: (s: Store) => void | Promise<void>;
  enabled?: (s: Store) => boolean;
  // Editor commands act on the focused editor, which may be a table cell.
  editor?: boolean;
  // Main-editor commands do not apply inside a table cell.
  mainOnly?: boolean;
}

// The editor that holds keyboard focus: the document or a table cell.
export function focusedEditor(): EditorView | null {
  const el = document.activeElement?.closest(".cm-content")?.closest(".cm-editor");
  return el ? EditorView.findFromDOM(el as HTMLElement) : null;
}

const plainInputFocused = () => {
  const el = document.activeElement;
  return !!el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA") && !el.closest(".cm-content");
};

const onEditor = (cmd: StateCommand | ((v: EditorView) => boolean | void)) => (s: Store) => {
  const view = focusedEditor() ?? s.view;
  if (view) (cmd as (v: EditorView) => boolean)(view);
};

const tabCommand = (n: number): Command => ({
  id: `tab.${n}`,
  label: (s) => (s.docs[n - 1] ? s.title(s.docs[n - 1]) : `Tab ${n}`),
  accel: { code: `Digit${n}` },
  run: (s) => s.docs[n - 1] && s.activate(s.docs[n - 1].id),
  enabled: (s) => !!s.docs[n - 1],
});

export const commands: Command[] = [
  { id: "app.settings", label: "Settings…", accel: { code: "Comma" }, run: (s) => s.toggle("settings") },
  { id: "app.quit", label: "Quit Vireo", accel: { code: "KeyQ" }, run: async (s) => (await s.closeAll()) && s.backend.quit() },

  { id: "file.newFile", label: "New File", accel: { code: "KeyN" }, run: (s) => s.newFile() },
  { id: "file.newTab", label: "New Tab", accel: { code: "KeyT" }, run: (s) => void s.newTab() },
  { id: "file.open", label: "Open…", accel: { code: "KeyO" }, run: (s) => s.promptOpen() },
  { id: "file.openFolder", label: "Open Folder…", accel: { code: "KeyO", shift: true }, run: (s) => s.promptOpenFolder() },
  { id: "file.quickOpen", label: "Search Files…", accel: { code: "KeyP" }, run: (s) => s.toggle("quickOpen"), enabled: (s) => !!s.workspace.root },
  { id: "file.closeWorkspace", label: "Close Workspace", run: (s) => s.closeWorkspace(), enabled: (s) => !!s.workspace.root },
  { id: "file.save", label: "Save", accel: { code: "KeyS" }, run: (s) => s.saveActive(), enabled: (s) => s.canSave(s.active) },
  { id: "file.saveAs", label: "Save As…", accel: { code: "KeyS", shift: true }, run: (s) => void (s.active && s.saveAs(s.active)) },
  { id: "file.closeTab", label: "Close Tab", accel: { code: "KeyW" }, run: (s) => void (s.active && s.closeTab(s.active.id)) },

  { id: "edit.undo", label: "Undo", accel: { code: "KeyZ" }, editor: true, run: onEditor(undo) },
  { id: "edit.redo", label: "Redo", accel: { code: "KeyZ", shift: true }, editor: true, run: onEditor(redo) },
  { id: "edit.find", label: "Find…", accel: { code: "KeyF" }, run: (s) => s.view && openSearchPanel(s.view) },

  { id: "insert.table", label: "Table", mainOnly: true, editor: true, run: onEditor(insertTable) },
  { id: "insert.codeBlock", label: "Code Block", accel: { code: "KeyK", shift: true }, mainOnly: true, editor: true, run: onEditor(insertCodeBlock) },
  { id: "insert.image", label: "Image…", mainOnly: true, editor: true, run: (s) => pickImage(s) },
  { id: "insert.task", label: "Task", mainOnly: true, editor: true, run: onEditor(toggleLinePrefix("- [ ] ")) },
  { id: "insert.rule", label: "Horizontal Rule", mainOnly: true, editor: true, run: onEditor(insertRule) },

  { id: "format.bold", label: "Bold", accel: { code: "KeyB" }, editor: true, run: onEditor(wrapSelection("**")) },
  { id: "format.italic", label: "Italic", accel: { code: "KeyI" }, editor: true, run: onEditor(wrapSelection("*")) },
  { id: "format.strike", label: "Strikethrough", editor: true, run: onEditor(wrapSelection("~~")) },
  { id: "format.code", label: "Inline Code", editor: true, run: onEditor(wrapSelection("`")) },
  { id: "format.h1", label: "Heading 1", accel: { code: "Digit1", alt: true }, mainOnly: true, editor: true, run: onEditor(makeHeading(1)) },
  { id: "format.h2", label: "Heading 2", accel: { code: "Digit2", alt: true }, mainOnly: true, editor: true, run: onEditor(makeHeading(2)) },
  { id: "format.h3", label: "Heading 3", accel: { code: "Digit3", alt: true }, mainOnly: true, editor: true, run: onEditor(makeHeading(3)) },
  { id: "format.list", label: "Bulleted List", mainOnly: true, editor: true, run: onEditor(toggleLinePrefix("- ")) },
  { id: "format.quote", label: "Quote", mainOnly: true, editor: true, run: onEditor(toggleLinePrefix("> ")) },
  { id: "format.link", label: "Link…", accel: { code: "KeyK" }, editor: true, run: onEditor((v: EditorView) => openLinkEditor(v)) },

  {
    id: "view.sidebar",
    label: (s) => (s.prefs.sidebarVisible ? "Hide File Sidebar" : "Show File Sidebar"),
    accel: { code: "Backslash" },
    run: (s) => s.setPref("sidebarVisible", !s.prefs.sidebarVisible),
  },
  {
    id: "view.toc",
    label: (s) => (s.active?.showTOC ? "Hide Table of Contents" : "Show Table of Contents"),
    accel: { code: "Backslash", alt: true },
    run: (s) => s.toggleTOC(),
    enabled: (s) => !!s.active,
  },
  { id: "view.focus", label: (s) => (s.ui.focusMode ? "Exit Focus Mode" : "Focus Mode"), accel: { code: "Period", shift: true }, run: (s) => s.toggle("focusMode") },
  { id: "view.zoomIn", label: "Zoom In", accel: { code: "Equal" }, run: (s) => s.setZoom(s.ui.zoom + 0.1) },
  { id: "view.zoomOut", label: "Zoom Out", accel: { code: "Minus" }, run: (s) => s.setZoom(s.ui.zoom - 0.1) },
  { id: "view.zoomReset", label: "Actual Size", accel: { code: "Digit0" }, run: (s) => s.setZoom(1) },

  ...[1, 2, 3, 4, 5, 6, 7, 8].map(tabCommand),
  {
    id: "tab.last",
    label: "Last Tab",
    accel: { code: "Digit9" },
    run: (s) => s.docs.length && s.activate(s.docs[s.docs.length - 1].id),
  },
];

export const commandById = new Map(commands.map((c) => [c.id, c]));

async function pickImage(s: Store) {
  const view = s.view;
  const doc = s.active;
  if (!view || !doc) return;
  const [path] = await s.backend.openDialog({ directory: false, multiple: false, images: true });
  if (!path) return;
  const src = doc.path ? relativeTo(dirname(doc.path), path) : path;
  insertImage(stem(basename(path)), src)(view);
  view.focus();
}

function relativeTo(fromDir: string, path: string): string {
  const a = fromDir.split("/").filter(Boolean);
  const b = path.split("/").filter(Boolean);
  let i = 0;
  while (i < a.length && i < b.length - 1 && a[i] === b[i]) i++;
  return [...a.slice(i).map(() => ".."), ...b.slice(i)].join("/") || basename(path);
}

export function labelOf(c: Command, s: Store): string {
  return typeof c.label === "function" ? c.label(s) : c.label;
}

export function isEnabled(c: Command, s: Store): boolean {
  if (c.enabled && !c.enabled(s)) return false;
  if (c.mainOnly && focusedEditor() && focusedEditor() !== s.view) return false;
  return true;
}

// A menu accelerator and the web view can both see one key press. Whichever
// runs a command first wins; the other is dropped.
let last = { id: "", at: 0 };

export function runCommand(s: Store, id: string, source: "key" | "menu") {
  const c = commandById.get(id);
  if (!c) return;
  if (source === "menu" && last.id === id && performance.now() - last.at < 400) return;
  if (id === "edit.undo" || id === "edit.redo") {
    if (plainInputFocused()) return void document.execCommand(id === "edit.undo" ? "undo" : "redo");
  }
  if (c.editor && !focusedEditor() && (plainInputFocused() || !s.view)) return;
  if (!isEnabled(c, s)) return;
  last = { id, at: performance.now() };
  void c.run(s);
}

function matches(a: Accel, e: KeyboardEvent): boolean {
  return e.code === a.code && !!a.shift === e.shiftKey && !!a.alt === e.altKey && !e.ctrlKey;
}

export function installKeyboard(s: Store) {
  window.addEventListener(
    "keydown",
    (e) => {
      if (!e.metaKey) return;
      const c = commands.find((c) => c.accel && matches(c.accel, e));
      if (!c) return;
      // Text fields keep their own undo, redo and select-all.
      if ((c.id === "edit.undo" || c.id === "edit.redo") && plainInputFocused()) return;
      e.preventDefault();
      e.stopPropagation();
      runCommand(s, c.id, "key");
    },
    true,
  );
}

export function accelString(a: Accel): string {
  return ["CmdOrCtrl", a.shift && "Shift", a.alt && "Alt", a.code].filter(Boolean).join("+");
}
