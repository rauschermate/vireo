import { convertFileSrc, invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { message, open, save } from "@tauri-apps/plugin-dialog";
import { openPath, openUrl } from "@tauri-apps/plugin-opener";
import type { Backend, FileText, Node } from "./backend";

export function tauriBackend(): Backend {
  const win = getCurrentWindow();
  return {
    kind: "tauri",
    readText: (path) => invoke<FileText>("read_text", { path }),
    writeText: (path, text) => invoke<number>("write_text", { path, text }),
    scanWorkspace: (root) => invoke<Node[]>("scan_workspace", { root }),
    createFile: (path, text) => invoke("create_file", { path, text }),
    createDir: (path) => invoke("create_dir", { path }),
    rename: (from, to) => invoke("rename_path", { from, to }),
    trash: (path) => invoke("trash_path", { path }),
    reveal: (path) => invoke("reveal_path", { path }),
    openExternal: (path) => openPath(path),
    openInTerminal: (path) => invoke("open_in_terminal", { path }),
    exists: (path) => invoke<boolean>("path_exists", { path }),
    loadPrefs: () => invoke<string>("load_prefs"),
    savePrefs: (json) => invoke("save_prefs", { json }),
    watch: (files, root) => invoke("watch_set", { files, root }),
    onFsChange: (cb) => void listen<string[]>("fs-change", (e) => cb(e.payload)),
    onMenu: (cb) => void listen<string>("menu", (e) => cb(e.payload)),
    // The event only signals that opens are queued; taking the queue avoids
    // double opens when a launch delivers files before the page listens.
    onOpenFiles: (cb) => {
      const take = () => invoke<string[]>("take_pending_opens").then((paths) => paths.length && cb(paths));
      void listen("open-files", take);
      void take();
    },
    async openDialog({ directory, multiple, images }) {
      const filters = directory
        ? undefined
        : images
          ? [{ name: "Images", extensions: ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "avif"] }]
          : [{ name: "Markdown", extensions: ["md", "markdown", "mdown", "mkd", "mkdn", "text", "txt"] }];
      const picked = await open({ directory, multiple, filters });
      if (!picked) return [];
      return Array.isArray(picked) ? picked : [picked];
    },
    saveDialog: (defaultPath) => save({ defaultPath, filters: [{ name: "Markdown", extensions: ["md"] }] }),
    async ask(text, { title, buttons }) {
      const [yes, no, cancel] = buttons;
      const result = await message(text, {
        title,
        kind: "warning",
        buttons: cancel ? { yes, no, cancel } : no ? { ok: yes, cancel: no } : { ok: yes },
      });
      if (result === yes || result === "Yes" || result === "Ok") return 0;
      if (cancel && (result === no || result === "No")) return 1;
      return buttons.length - 1;
    },
    openUrl: (url) => openUrl(url),
    fileSrc: (path) => convertFileSrc(path),
    setTitle: (title) => void win.setTitle(title),
    setDocumentEdited: (edited) => void invoke("set_document_edited", { edited }),
    setRepresentedFile: (path) => void invoke("set_represented_file", { path }),
    quit: () => invoke("quit_app"),
    onCloseRequested: (cb) =>
      void win.onCloseRequested(async (event) => {
        event.preventDefault();
        if (await cb()) await invoke("quit_app");
      }),
  };
}
