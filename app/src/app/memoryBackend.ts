import type { Backend, Node } from "./backend";

// An in-memory file system for running the app in a plain browser. Tests
// drive it through window.__host: change files "on disk", answer dialogs,
// and fire menu commands.

const ROOT = "/Users/demo/Notes";
const MARKDOWN = /\.(md|markdown|mdown|mkd|mkdn|text)$/i;

export interface MemoryHost {
  files: Map<string, { text: string; mtime: number }>;
  dirs: Set<string>;
  externalWrite(path: string, text: string): void;
  externalDelete(path: string): void;
  menu(id: string): void;
  openFiles(paths: string[]): void;
  dialogAnswers: string[][];
  saveAnswers: (string | null)[];
  askAnswers: number[];
  asked: string[];
  opened: string[];
  title: string;
  edited: boolean;
  closeRequest(): Promise<boolean>;
}

const parent = (p: string) => p.slice(0, p.lastIndexOf("/")) || "/";
const base = (p: string) => p.slice(p.lastIndexOf("/") + 1);

export async function memoryBackend(): Promise<Backend> {
  const files = new Map<string, { text: string; mtime: number }>();
  const dirs = new Set<string>([ROOT, `${ROOT}/Projects`, `${ROOT}/Projects/Vireo`, `${ROOT}/Journal`]);
  const now = () => Date.now();
  const put = (path: string, text: string) => files.set(path, { text, mtime: now() });
  const fetchText = async (name: string) => {
    try {
      const r = await fetch(`/${name}`);
      return r.ok ? await r.text() : `# ${name}\n`;
    } catch {
      return `# ${name}\n`;
    }
  };
  put(`${ROOT}/Welcome.md`, await fetchText("welcome.md"));
  put(`${ROOT}/Lists.md`, await fetchText("lists.md"));
  put(`${ROOT}/Projects/Roadmap.md`, "# Roadmap\n\n## Now\n\n- [ ] Ship the editor core\n- [ ] Build the shell\n\n## Later\n\n- Windows build\n");
  put(`${ROOT}/Projects/Vireo/Ideas.md`, "# Ideas\n\nA place for [[wiki links]] one day.\n");
  put(`${ROOT}/Journal/2026-10-27.md`, "# Monday\n\nWrote the shell.\n");
  put(`${ROOT}/Journal/2026-10-28.md`, "# Tuesday\n\nTested the shell.\n");
  if (new URLSearchParams(location.search).has("big")) put(`${ROOT}/Big.md`, await fetchText("formatting-dense.md"));

  const fsListeners: ((paths: string[]) => void)[] = [];
  const menuListeners: ((id: string) => void)[] = [];
  const openListeners: ((paths: string[]) => void)[] = [];
  let closeHandler: (() => Promise<boolean>) | null = null;
  const changed = (paths: string[]) => setTimeout(() => fsListeners.forEach((cb) => cb(paths)), 20);

  const host: MemoryHost = {
    files,
    dirs,
    externalWrite(path, text) {
      put(path, text);
      changed([path]);
    },
    externalDelete(path) {
      files.delete(path);
      changed([path]);
    },
    menu: (id) => menuListeners.forEach((cb) => cb(id)),
    openFiles: (paths) => openListeners.forEach((cb) => cb(paths)),
    dialogAnswers: [],
    saveAnswers: [],
    askAnswers: [],
    asked: [],
    opened: [],
    title: "",
    edited: false,
    closeRequest: () => (closeHandler ? closeHandler() : Promise.resolve(true)),
  };
  (window as any).__host = host;

  const missing = (path: string) => Promise.reject(new Error(`No such file: ${path}`));

  return {
    kind: "memory",
    async readText(path) {
      const f = files.get(path);
      return f ? { text: f.text, mtime: f.mtime } : missing(path);
    },
    async writeText(path, text) {
      if (!dirs.has(parent(path))) return missing(parent(path));
      put(path, text);
      changed([path]);
      return files.get(path)!.mtime;
    },
    async scanWorkspace(root) {
      if (!dirs.has(root)) throw new Error("The folder does not exist.");
      const title = (text: string) => /^\s*# (.+)$/m.exec(text.split("\n").find((l) => l.trim()) ?? "")?.[1]?.trim() ?? null;
      const walk = (dir: string): Node[] => {
        const nodes: Node[] = [];
        for (const d of dirs) {
          if (parent(d) !== dir || d === dir) continue;
          const children = walk(d);
          const empty = ![...dirs].some((x) => parent(x) === d && x !== d) && ![...files.keys()].some((f) => parent(f) === d);
          if (children.length || empty) nodes.push({ name: base(d), path: d, dir: true, title: null, mtime: 0, children });
        }
        for (const [f, v] of files) if (parent(f) === dir && MARKDOWN.test(f)) nodes.push({ name: base(f), path: f, dir: false, title: title(v.text), mtime: v.mtime, children: [] });
        return nodes.sort((a, b) => Number(b.dir) - Number(a.dir) || a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }));
      };
      return walk(root);
    },
    async createFile(path, text) {
      if (files.has(path)) throw new Error("A file with that name already exists.");
      put(path, text);
      changed([path]);
    },
    async createDir(path) {
      dirs.add(path);
      changed([path]);
    },
    async rename(from, to) {
      if ((files.has(to) || dirs.has(to)) && from.toLowerCase() !== to.toLowerCase()) throw new Error("A file with that name already exists.");
      if (files.has(from)) {
        files.set(to, files.get(from)!);
        files.delete(from);
      } else if (dirs.has(from)) {
        for (const d of [...dirs]) if (d === from || d.startsWith(from + "/")) (dirs.delete(d), dirs.add(to + d.slice(from.length)));
        for (const [f, v] of [...files]) if (f.startsWith(from + "/")) (files.delete(f), files.set(to + f.slice(from.length), v));
      }
      changed([from, to]);
    },
    async trash(path) {
      files.delete(path);
      for (const d of [...dirs]) if (d === path || d.startsWith(path + "/")) dirs.delete(d);
      for (const f of [...files.keys()]) if (f.startsWith(path + "/")) files.delete(f);
      changed([path]);
    },
    async reveal(path) {
      host.opened.push(`reveal:${path}`);
    },
    async openExternal(path) {
      host.opened.push(`open:${path}`);
    },
    async openInTerminal(path) {
      host.opened.push(`terminal:${path}`);
    },
    async exists(path) {
      return files.has(path) || dirs.has(path);
    },
    async loadPrefs() {
      return localStorage.getItem("vireo-prefs") ?? JSON.stringify({ workspace: ROOT });
    },
    async savePrefs(json) {
      try {
        localStorage.setItem("vireo-prefs", json);
      } catch {}
    },
    async watch() {},
    onFsChange: (cb) => void fsListeners.push(cb),
    onMenu: (cb) => void menuListeners.push(cb),
    onOpenFiles: (cb) => void openListeners.push(cb),
    async openDialog() {
      return host.dialogAnswers.shift() ?? [];
    },
    async saveDialog() {
      return host.saveAnswers.shift() ?? null;
    },
    async ask(message, { buttons }) {
      host.asked.push(message);
      return host.askAnswers.shift() ?? buttons.length - 1;
    },
    async openUrl(url) {
      host.opened.push(url);
    },
    fileSrc: (path) => path,
    setTitle: (title) => {
      host.title = title;
      document.title = title;
    },
    setDocumentEdited: (edited) => void (host.edited = edited),
    setRepresentedFile: () => {},
    async quit() {},
    onCloseRequested: (cb) => void (closeHandler = cb),
  };
}
