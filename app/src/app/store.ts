import { EditorSelection, EditorState, StateEffect } from "@codemirror/state";
import { EditorView, ViewUpdate } from "@codemirror/view";
import { createState } from "../editor/editor";
import { openLink, resolveResource } from "../editor/host";
import type { Backend, FileStat, FileText, Node } from "./backend";
import { currentHeading, Heading, outline, slug } from "./outline";
import { basename, dirname, isMarkdown, join, resolve, stem, uniqueName, validateName } from "./paths";
import { parsePrefs, Prefs, pushRecent, tocOpenByDefault } from "./prefs";

// The app state outside React. Components read fields directly and re-render
// on emit(); the editor's keystroke path never goes through React.

export interface Doc {
  id: string;
  path: string | null;
  // A name for an untitled tab, set by rename.
  customTitle: string | null;
  // The editor state while the tab is inactive; the view holds it otherwise.
  state: EditorState;
  // The disk version this tab last read or wrote. A save compares the disk
  // against it to detect a newer version written by someone else.
  disk: FileStat | null;
  dirty: boolean;
  saveError: string | null;
  conflict: boolean;
  showTOC: boolean;
  scroll: StateEffect<unknown> | null;
  welcome: boolean;
  saving: Promise<boolean> | null;
  prompting: boolean;
}

export interface WordCount {
  words: number;
  characters: number;
}

const AUTOSAVE_DELAY = 500;
const RESCAN_DELAY = 350;
const DERIVED_DELAY = 250;
export const ZOOM_MIN = 0.6;
export const ZOOM_MAX = 3;

let nextId = 1;

export class Store {
  docs: Doc[] = [];
  activeId: string | null = null;
  view: EditorView | null = null;
  workspace = { root: null as string | null, tree: [] as Node[], status: "idle" as "idle" | "loading" | "ready" | "error", error: null as string | null };
  ui = {
    focusMode: false,
    zoom: 1,
    quickOpen: false,
    settings: false,
    tabSearch: false,
    expanded: new Set<string>(),
    selection: new Set<string>(),
    sidebarQuery: "",
    // A path in the sidebar or "tab:<id>" whose name is being edited.
    renaming: null as string | null,
    pinnedShown: 6,
    recentsExpanded: false,
    everythingCollapsed: false,
    outline: [] as Heading[],
    currentHeading: -1,
    wordCount: { words: 0, characters: 0 } as WordCount,
  };

  private version = 0;
  private listeners = new Set<() => void>();
  private autosaveTimers = new Map<string, number>();
  private rescanTimer = 0;
  private derivedTimer = 0;
  private prefsTimer = 0;

  constructor(
    readonly backend: Backend,
    public prefs: Prefs,
  ) {
    backend.onFsChange((paths) => this.handleFsChange(paths));
  }

  static async create(backend: Backend): Promise<Store> {
    return new Store(backend, parsePrefs(await backend.loadPrefs()));
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };
  getVersion = () => this.version;

  emit() {
    this.version++;
    for (const l of this.listeners) l();
  }

  // ---------------------------------------------------------------- docs

  get active(): Doc | null {
    return this.docs.find((d) => d.id === this.activeId) ?? null;
  }

  stateOf(doc: Doc): EditorState {
    return doc.id === this.activeId && this.view ? this.view.state : doc.state;
  }

  textOf(doc: Doc): string {
    return this.stateOf(doc).doc.toString();
  }

  title(doc: Doc): string {
    if (doc.customTitle) return doc.customTitle;
    if (!doc.path) return "Untitled";
    const name = basename(doc.path);
    return isMarkdown(name) ? stem(name) : name;
  }

  private makeState(text: string, doc: Doc, selection?: EditorSelection): EditorState {
    const state = createState(text, [
      resolveResource.of((src) => this.resource(doc, src)),
      openLink.of((target) => void this.followLink(doc, target)),
      EditorView.updateListener.of((u) => this.onUpdate(doc, u)),
    ]);
    if (!selection) return state;
    const clamp = (n: number) => Math.min(n, text.length);
    return state.update({ selection: EditorSelection.create(selection.ranges.map((r) => EditorSelection.range(clamp(r.anchor), clamp(r.head)))) }).state;
  }

  private newDoc(path: string | null, text: string, disk: FileStat | null, welcome = false): Doc {
    const doc: Doc = {
      id: `doc-${nextId++}`,
      path,
      customTitle: welcome ? "Welcome" : null,
      state: undefined as unknown as EditorState,
      disk,
      dirty: false,
      saveError: null,
      conflict: false,
      showTOC: tocOpenByDefault(this.prefs.tocDefault, text),
      scroll: null,
      welcome,
      saving: null,
      prompting: false,
    };
    doc.state = this.makeState(text, doc);
    return doc;
  }

  private pristine(doc: Doc | null): doc is Doc {
    return !!doc && !doc.path && !doc.dirty && !doc.welcome && this.stateOf(doc).doc.length === 0;
  }

  attachView(view: EditorView) {
    this.view = view;
    const doc = this.active;
    if (doc) view.setState(doc.state);
    this.refreshDerived();
  }

  private captureActive() {
    const doc = this.active;
    if (doc && this.view) {
      doc.state = this.view.state;
      doc.scroll = this.view.scrollSnapshot();
    }
  }

  activate(id: string) {
    if (id === this.activeId) return;
    this.captureActive();
    this.activeId = id;
    const doc = this.active;
    if (doc && this.view) {
      this.view.setState(doc.state);
      if (doc.scroll) this.view.dispatch({ effects: doc.scroll });
    }
    this.refreshDerived();
    this.syncWindow();
    this.emit();
  }

  focusEditor() {
    requestAnimationFrame(() => this.view?.focus());
  }

  private onUpdate(doc: Doc, u: ViewUpdate) {
    if (u.docChanged) {
      if (!doc.dirty) {
        doc.dirty = true;
        this.syncWindow();
        this.emit();
      }
      this.scheduleAutosave(doc);
      this.scheduleDerived();
    } else if (u.selectionSet) {
      const index = currentHeading(this.ui.outline, u.state.selection.main.head);
      if (index !== this.ui.currentHeading) {
        this.ui.currentHeading = index;
        this.emit();
      }
    }
  }

  private scheduleDerived() {
    clearTimeout(this.derivedTimer);
    this.derivedTimer = window.setTimeout(() => this.refreshDerived(), DERIVED_DELAY);
  }

  // The outline and the word count, for the active tab.
  refreshDerived() {
    const doc = this.active;
    const text = doc ? this.textOf(doc) : "";
    this.ui.outline = outline(text);
    this.ui.currentHeading = doc ? currentHeading(this.ui.outline, this.stateOf(doc).selection.main.head) : -1;
    this.ui.wordCount = this.prefs.showWordCount ? countWords(text) : { words: 0, characters: 0 };
    this.emit();
  }

  newTab() {
    const doc = this.newDoc(null, "", null);
    this.docs.push(doc);
    this.activate(doc.id);
    this.updateWatch();
    this.focusEditor();
    return doc;
  }

  openWelcome(text: string) {
    const doc = this.newDoc(null, text, null, true);
    this.docs.push(doc);
    this.activate(doc.id);
  }

  async openPaths(paths: string[]) {
    for (const path of paths) {
      if (isMarkdown(path) || /\.txt$/i.test(path)) await this.openPath(path);
      else if (await this.isDir(path)) await this.openWorkspace(path);
      else await this.openPath(path);
    }
  }

  private async isDir(path: string): Promise<boolean> {
    try {
      await this.backend.scanWorkspace(path);
      return true;
    } catch {
      return false;
    }
  }

  async openPath(path: string, anchor?: string, focus = true) {
    const existing = this.docs.find((d) => d.path === path);
    if (existing) {
      this.activate(existing.id);
      if (anchor) this.scrollToAnchor(existing, anchor);
      if (focus) this.focusEditor();
      return existing;
    }
    let file: FileText;
    try {
      file = await this.backend.readText(path);
    } catch (e) {
      await this.backend.ask(errorText(e), { title: `Couldn't open “${basename(path)}”`, buttons: ["OK"] });
      return null;
    }
    const doc = this.newDoc(path, file.text, { mtime: file.mtime, hash: file.hash });
    // An empty untitled tab gives way to the opened file instead of staying.
    const active = this.active;
    if (this.pristine(active)) {
      const index = this.docs.indexOf(active);
      this.docs[index] = doc;
      this.activeId = null;
    } else {
      this.docs.push(doc);
    }
    this.prefs.recentFiles = pushRecent(this.prefs.recentFiles, path);
    this.savePrefs();
    this.activate(doc.id);
    this.updateWatch();
    if (anchor) requestAnimationFrame(() => this.scrollToAnchor(doc, anchor));
    if (focus) this.focusEditor();
    return doc;
  }

  async promptOpen() {
    const picked = await this.backend.openDialog({ directory: false, multiple: true });
    await this.openPaths(picked);
  }

  async promptOpenFolder() {
    const [dir] = await this.backend.openDialog({ directory: true, multiple: false });
    if (dir) await this.openWorkspace(dir);
  }

  // ⌘N: a real file named Untitled.md next to the active file, else in the
  // workspace, else wherever the user picks.
  async newFile() {
    const dir = this.active?.path ? dirname(this.active.path) : this.workspace.root;
    if (!dir) {
      const path = await this.backend.saveDialog("Untitled.md");
      if (!path) return;
      try {
        await this.backend.createFile(path, "");
      } catch (e) {
        if (!(await this.backend.exists(path))) return void this.alert("Couldn't create the file", e);
      }
      await this.openPath(path);
      return;
    }
    await this.createFileIn(dir);
  }

  private scheduleAutosave(doc: Doc) {
    if (!this.prefs.autoSave || !doc.path || doc.conflict || doc.saveError) return;
    clearTimeout(this.autosaveTimers.get(doc.id));
    this.autosaveTimers.set(doc.id, window.setTimeout(() => void this.save(doc), AUTOSAVE_DELAY));
  }

  // ⌘S is only needed when autosave is off, for untitled tabs, or after a
  // failed save.
  canSave(doc: Doc | null): boolean {
    return !!doc && !(this.prefs.autoSave && doc.path && !doc.saveError && !doc.conflict);
  }

  async saveActive() {
    const doc = this.active;
    if (!doc) return;
    if (doc.saveError) doc.saveError = null;
    await this.save(doc);
  }

  // Serialized per tab: a save waits for the one before it.
  save(doc: Doc, force = false): Promise<boolean> {
    if (!doc.path) return this.saveAs(doc);
    clearTimeout(this.autosaveTimers.get(doc.id));
    const run = async (): Promise<boolean> => {
      const path = doc.path!;
      const text = this.textOf(doc);
      try {
        // Hashes, not text, cross the bridge on the common path.
        let current: FileStat | null = null;
        try {
          current = await this.backend.statText(path);
        } catch {}
        if (!force && current && doc.disk && current.hash !== doc.disk.hash) {
          const disk = await this.backend.readText(path);
          if (disk.text !== text) return await this.presentConflict(doc, disk);
        }
        doc.disk = await this.backend.writeText(path, text);
        doc.saveError = null;
        doc.conflict = false;
        if (this.textOf(doc) === text) doc.dirty = false;
        else this.scheduleAutosave(doc);
        this.syncWindow();
        this.emit();
        return true;
      } catch (e) {
        doc.saveError = errorText(e);
        this.emit();
        if (this.prefs.autoSave) void this.reportAutosaveError(doc);
        return false;
      }
    };
    const previous = doc.saving ?? Promise.resolve(true);
    const next = previous.then(run, run);
    doc.saving = next;
    void next.finally(() => {
      if (doc.saving === next) doc.saving = null;
    });
    return next;
  }

  async saveAs(doc: Doc): Promise<boolean> {
    const title = this.title(doc);
    const suggested = /\.md$/i.test(title) ? title : `${title}.md`;
    const start = doc.path ? join(dirname(doc.path), suggested) : this.workspace.root ? join(this.workspace.root, suggested) : suggested;
    const path = await this.backend.saveDialog(start);
    if (!path) return false;
    const text = this.textOf(doc);
    try {
      doc.disk = await this.backend.writeText(path, text);
    } catch (e) {
      await this.alert(`Couldn't save “${title}”`, e);
      return false;
    }
    doc.path = path;
    doc.customTitle = null;
    doc.welcome = false;
    doc.saveError = null;
    doc.conflict = false;
    if (this.textOf(doc) === text) doc.dirty = false;
    this.prefs.recentFiles = pushRecent(this.prefs.recentFiles, path);
    this.savePrefs();
    this.updateWatch();
    this.syncWindow();
    this.scheduleRescan();
    this.emit();
    return true;
  }

  private async reportAutosaveError(doc: Doc) {
    if (doc.prompting) return;
    doc.prompting = true;
    const choice = await this.backend.ask(`${doc.saveError} Your edits are still open and marked unsaved.`, {
      title: `Couldn't auto-save “${this.title(doc)}”`,
      buttons: ["Try Again", "OK"],
    });
    doc.prompting = false;
    if (choice === 0) {
      doc.saveError = null;
      await this.save(doc);
    }
  }

  // The disk has a newer version and the tab has unsaved edits.
  private async presentConflict(doc: Doc, disk: FileText): Promise<boolean> {
    doc.conflict = true;
    this.emit();
    if (doc.prompting) return false;
    doc.prompting = true;
    const choice = await this.backend.ask("Vireo kept your unsaved edits and did not overwrite the newer disk version.", {
      title: `“${basename(doc.path!)}” changed on disk`,
      buttons: ["Keep Mine", "Reload Disk", "Cancel"],
    });
    doc.prompting = false;
    if (choice === 0) {
      doc.disk = { mtime: disk.mtime, hash: disk.hash };
      doc.conflict = false;
      return this.save(doc, true);
    }
    if (choice === 1) {
      this.reload(doc, disk);
      return true;
    }
    return false;
  }

  // Replaces the tab content with the disk version. The undo history restarts,
  // as in Vireo, so undo cannot mix the two versions.
  private reload(doc: Doc, disk: FileText) {
    const isActive = doc.id === this.activeId && this.view;
    const scroll = isActive ? this.view!.scrollSnapshot() : doc.scroll;
    const state = this.makeState(disk.text, doc, this.stateOf(doc).selection);
    doc.disk = { mtime: disk.mtime, hash: disk.hash };
    doc.dirty = false;
    doc.conflict = false;
    doc.saveError = null;
    if (isActive) {
      this.view!.setState(state);
      if (scroll) this.view!.dispatch({ effects: scroll });
    } else {
      doc.state = state;
    }
    this.refreshDerived();
    this.syncWindow();
    this.emit();
  }

  private async handleFsChange(paths: string[]) {
    void this.workspaceChanged(paths);
    for (const doc of this.docs) {
      if (doc.path && paths.includes(doc.path)) await this.checkDisk(doc);
    }
  }

  // A changed file that the tree already shows only needs its title and
  // date refreshed. Anything else (new, deleted, a folder) rescans.
  private async workspaceChanged(paths: string[]) {
    const root = this.workspace.root;
    if (!root || this.workspace.status !== "ready") return;
    // Other file types never show in the tree. A path without an extension
    // may be a folder, so it counts.
    const under = paths.filter((p) => (p === root || p.startsWith(root + "/")) && (isMarkdown(p) || !/\.[^/]+$/.test(basename(p))));
    if (!under.length) return;
    const nodes = new Map(this.files().map((f) => [f.path, f]));
    for (const path of under) {
      const node = nodes.get(path);
      if (!node) {
        this.stats.rescanCause = path;
        return this.scheduleRescan();
      }
      try {
        const info = await this.backend.fileInfo(path);
        node.title = info.title;
        node.mtime = info.mtime;
      } catch {
        return this.scheduleRescan();
      }
    }
    this.emit();
  }

  private async checkDisk(doc: Doc) {
    if (doc.saving) await doc.saving;
    let stat: FileStat;
    try {
      stat = await this.backend.statText(doc.path!);
    } catch {
      return;
    }
    // Our own save, or a touch that kept the content.
    if (doc.disk && stat.hash === doc.disk.hash) return;
    let disk: FileText;
    try {
      disk = await this.backend.readText(doc.path!);
    } catch {
      return;
    }
    if (disk.text === this.textOf(doc)) {
      doc.disk = { mtime: disk.mtime, hash: disk.hash };
      return;
    }
    if (!doc.dirty) this.reload(doc, disk);
    else await this.presentConflict(doc, disk);
  }

  // Asks about unsaved edits. True when the tab may close.
  async prepareToClose(doc: Doc): Promise<boolean> {
    if (!doc.dirty) return true;
    if (this.prefs.autoSave && doc.path && !doc.conflict) {
      doc.saveError = null;
      if (await this.save(doc)) return true;
      if (doc.conflict) return false;
      return this.closeAfterFailedSave(doc);
    }
    this.activate(doc.id);
    const choice = await this.backend.ask("Your changes will be lost if you don't save them.", {
      title: `Save changes to “${this.title(doc)}”?`,
      buttons: ["Save", "Don't Save", "Cancel"],
    });
    if (choice === 1) return true;
    if (choice === 2) return false;
    doc.saveError = null;
    if (await this.save(doc)) return true;
    if (doc.conflict || !doc.path) return false;
    return this.closeAfterFailedSave(doc);
  }

  private async closeAfterFailedSave(doc: Doc): Promise<boolean> {
    for (;;) {
      const choice = await this.backend.ask(`${doc.saveError ?? "The file could not be written."} Your edits are still in Vireo.`, {
        title: `Couldn't save “${this.title(doc)}”`,
        buttons: ["Try Again", "Close Without Saving", "Cancel"],
      });
      if (choice === 1) return true;
      if (choice === 2) return false;
      doc.saveError = null;
      if (await this.save(doc)) return true;
    }
  }

  async closeTab(id: string): Promise<boolean> {
    const doc = this.docs.find((d) => d.id === id);
    if (!doc || !(await this.prepareToClose(doc))) return false;
    this.discard(doc);
    return true;
  }

  // Removes a tab without asking, for files deleted from the sidebar.
  private discard(doc: Doc) {
    clearTimeout(this.autosaveTimers.get(doc.id));
    const index = this.docs.indexOf(doc);
    if (index < 0) return;
    if (doc.id === this.activeId) this.captureActive();
    this.docs.splice(index, 1);
    // Vireo always keeps one tab.
    if (this.docs.length === 0) this.docs.push(this.newDoc(null, "", null));
    if (doc.id === this.activeId) {
      this.activeId = null;
      this.activate(this.docs[Math.min(index, this.docs.length - 1)].id);
    }
    this.updateWatch();
    this.emit();
  }

  async closeOthers(id: string) {
    for (const doc of this.docs.filter((d) => d.id !== id)) if (!(await this.closeTab(doc.id))) return;
  }

  async closeRight(id: string) {
    const index = this.docs.findIndex((d) => d.id === id);
    for (const doc of this.docs.slice(index + 1)) if (!(await this.closeTab(doc.id))) return;
  }

  async closeAll(): Promise<boolean> {
    for (const doc of [...this.docs]) if (doc.dirty && !(await this.prepareToClose(doc))) return false;
    return true;
  }

  async renameDoc(doc: Doc, raw: string) {
    const name = raw.trim();
    if (!doc.path) {
      doc.customTitle = name || null;
      this.emit();
      return;
    }
    if (!name) return;
    const invalid = validateName(name);
    if (invalid) return void this.alert("Couldn't rename", invalid);
    const fileName = isMarkdown(name) ? name : `${name}.md`;
    const dest = join(dirname(doc.path), fileName);
    if (dest === doc.path) return;
    if (await this.backend.exists(dest) && dest.toLowerCase() !== doc.path.toLowerCase()) {
      return void this.alert("Couldn't rename", `A file named “${fileName}” already exists.`);
    }
    if (doc.dirty && !(await this.save(doc))) return;
    try {
      await this.backend.rename(doc.path, dest);
    } catch (e) {
      return void this.alert("Couldn't rename", e);
    }
    this.relocate(doc.path, dest);
    this.scheduleRescan();
  }

  // Points tabs, pins and recents at a moved file or folder.
  private relocate(from: string, to: string) {
    const move = (p: string) => (p === from ? to : p.startsWith(from + "/") ? to + p.slice(from.length) : p);
    for (const doc of this.docs) if (doc.path) doc.path = move(doc.path);
    this.prefs.recentFiles = this.prefs.recentFiles.map(move);
    const root = this.workspace.root;
    if (root && this.prefs.pinned[root]) this.prefs.pinned[root] = this.prefs.pinned[root].map(move);
    this.ui.expanded = new Set([...this.ui.expanded].map(move));
    this.savePrefs();
    this.updateWatch();
    this.syncWindow();
    this.emit();
  }

  // --------------------------------------------------------------- links

  private resource(doc: Doc, src: string): string {
    if (/^(https?|data|blob|asset):/i.test(src) || !doc.path) return src;
    let decoded = src;
    try {
      decoded = decodeURI(src);
    } catch {}
    return this.backend.fileSrc(resolve(dirname(doc.path), decoded));
  }

  async followLink(doc: Doc, target: string) {
    if (/^[a-z][a-z0-9+.-]*:/i.test(target)) return void this.backend.openUrl(target);
    const [file, anchor] = target.split("#", 2);
    if (!file) return void this.scrollToAnchor(doc, anchor ?? "");
    if (!doc.path) return;
    let decoded = file;
    try {
      decoded = decodeURI(file);
    } catch {}
    const path = resolve(dirname(doc.path), decoded);
    if (!(await this.backend.exists(path))) return;
    if (isMarkdown(path)) await this.openPath(path, anchor);
    else await this.backend.openExternal(path);
  }

  scrollToAnchor(doc: Doc, anchor: string) {
    let wanted = anchor;
    try {
      wanted = decodeURIComponent(anchor);
    } catch {}
    wanted = wanted.toLowerCase();
    const heading = outline(this.textOf(doc)).find((h) => slug(h.text) === wanted);
    if (heading) this.scrollTo(heading.from);
  }

  scrollTo(pos: number) {
    if (!this.view) return;
    this.view.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y: "start", yMargin: 24 }) });
    this.view.focus();
  }

  // ----------------------------------------------------------- workspace

  async openWorkspace(root: string, reveal = true) {
    this.workspace = { root, tree: [], status: "loading", error: null };
    this.ui.expanded = new Set();
    this.ui.selection = new Set();
    this.ui.everythingCollapsed = false;
    this.ui.pinnedShown = 6;
    this.prefs.lastWorkspace = root;
    this.prefs.recentWorkspaces = pushRecent(this.prefs.recentWorkspaces, root);
    if (reveal) this.prefs.sidebarVisible = true;
    this.savePrefs();
    this.emit();
    await this.rescan();
    this.updateWatch();
  }

  closeWorkspace() {
    this.workspace = { root: null, tree: [], status: "idle", error: null };
    this.prefs.lastWorkspace = null;
    this.savePrefs();
    this.updateWatch();
    this.emit();
  }

  stats = { rescans: 0, rescanCause: "" };

  async rescan() {
    const root = this.workspace.root;
    if (!root) return;
    this.stats.rescans++;
    try {
      const tree = await this.backend.scanWorkspace(root);
      if (this.workspace.root !== root) return;
      this.workspace = { root, tree, status: "ready", error: null };
    } catch (e) {
      if (this.workspace.root !== root) return;
      this.workspace = { root, tree: [], status: "error", error: errorText(e) };
    }
    this.emit();
  }

  private scheduleRescan() {
    clearTimeout(this.rescanTimer);
    this.rescanTimer = window.setTimeout(() => void this.rescan(), RESCAN_DELAY);
  }

  files(): Node[] {
    const out: Node[] = [];
    const walk = (nodes: Node[]) => {
      for (const n of nodes) n.dir ? walk(n.children) : out.push(n);
    };
    walk(this.workspace.tree);
    return out;
  }

  label(node: Node): string {
    if (node.dir) return node.name;
    if (this.prefs.fileLabel === "title" && node.title) return node.title;
    return isMarkdown(node.name) ? stem(node.name) : node.name;
  }

  get pinned(): string[] {
    const root = this.workspace.root;
    return root ? (this.prefs.pinned[root] ?? []) : [];
  }

  togglePin(path: string) {
    const root = this.workspace.root;
    if (!root) return;
    const list = this.pinned;
    this.prefs.pinned = { ...this.prefs.pinned, [root]: list.includes(path) ? list.filter((p) => p !== path) : [path, ...list] };
    this.savePrefs();
    this.emit();
  }

  private taken(dir: string): (name: string) => boolean {
    const find = (nodes: Node[]): Node[] | null => {
      for (const n of nodes) {
        if (n.path === dir) return n.children;
        if (n.dir && dir.startsWith(n.path + "/")) return find(n.children);
      }
      return null;
    };
    const siblings = dir === this.workspace.root ? this.workspace.tree : (find(this.workspace.tree) ?? []);
    const names = new Set(siblings.map((n) => n.name.toLowerCase()));
    return (name) => names.has(name.toLowerCase());
  }

  async createFileIn(dir: string) {
    const name = uniqueName("Untitled", ".md", this.taken(dir));
    const path = join(dir, name);
    try {
      await this.backend.createFile(path, "");
    } catch (e) {
      return void this.alert("Couldn't create the file", e);
    }
    if (dir !== this.workspace.root) this.ui.expanded.add(dir);
    await this.rescan();
    // The sidebar's name field takes focus for the rename, not the editor.
    await this.openPath(path, undefined, false);
    this.ui.renaming = path;
    this.emit();
  }

  async createFolderIn(dir: string) {
    const name = uniqueName("Untitled Folder", "", this.taken(dir));
    const path = join(dir, name);
    try {
      await this.backend.createDir(path);
    } catch (e) {
      return void this.alert("Couldn't create the folder", e);
    }
    if (dir !== this.workspace.root) this.ui.expanded.add(dir);
    await this.rescan();
    this.ui.renaming = path;
    this.emit();
  }

  async duplicate(path: string) {
    const dir = dirname(path);
    const name = basename(path);
    const ext = name.includes(".") ? name.slice(name.lastIndexOf(".")) : "";
    const copy = uniqueName(`${stem(name)} copy`, ext, this.taken(dir));
    try {
      const { text } = await this.backend.readText(path);
      await this.backend.createFile(join(dir, copy), text);
    } catch (e) {
      return void this.alert("Couldn't duplicate", e);
    }
    await this.rescan();
  }

  async renamePath(path: string, raw: string, isDir: boolean) {
    const name = raw.trim();
    const invalid = validateName(name);
    if (invalid) return void this.alert("Couldn't rename", invalid);
    const old = basename(path);
    const ext = !isDir && old.includes(".") && !name.includes(".") ? old.slice(old.lastIndexOf(".")) : "";
    const dest = join(dirname(path), name + ext);
    if (dest === path) return;
    try {
      await this.backend.rename(path, dest);
    } catch (e) {
      return void this.alert("Couldn't rename", e);
    }
    this.relocate(path, dest);
    await this.rescan();
  }

  async moveInto(paths: string[], dir: string) {
    for (const path of paths) {
      if (dir === path || dir.startsWith(path + "/") || dirname(path) === dir) continue;
      const dest = join(dir, basename(path));
      try {
        await this.backend.rename(path, dest);
      } catch (e) {
        await this.alert("Couldn't move", e);
        continue;
      }
      this.relocate(path, dest);
    }
    this.ui.expanded.add(dir);
    await this.rescan();
  }

  // Moves to the Trash. Asks first only when unsaved tabs would go with it,
  // or for several items, as Vireo does.
  async deletePaths(paths: string[]) {
    const under = (doc: Doc) => doc.path && paths.some((p) => doc.path === p || doc.path!.startsWith(p + "/"));
    const affected = this.docs.filter((d) => under(d) && d.dirty);
    let question: string | null = null;
    if (affected.length) {
      if (paths.length === 1 && affected.length === 1 && affected[0].path === paths[0]) question = `“${basename(paths[0])}” has unsaved changes. Delete anyway?`;
      else if (paths.length === 1) question = `“${basename(paths[0])}” contains ${affected.length} unsaved files. Delete anyway?`;
      else question = `${affected.length} of ${paths.length} selected items have unsaved changes. Delete anyway?`;
    } else if (paths.length > 1) {
      question = `Delete ${paths.length} items?`;
    }
    if (question && (await this.backend.ask("", { title: question, buttons: ["Delete", "Cancel"] })) !== 0) return;
    for (const path of paths) {
      try {
        await this.backend.trash(path);
      } catch (e) {
        await this.alert("Couldn't delete", e);
        continue;
      }
      for (const doc of this.docs.filter(under)) this.discard(doc);
      const root = this.workspace.root;
      if (root && this.prefs.pinned[root]) this.prefs.pinned[root] = this.prefs.pinned[root].filter((p) => p !== path && !p.startsWith(path + "/"));
    }
    this.ui.selection = new Set();
    this.savePrefs();
    await this.rescan();
  }

  relativePath(path: string): string {
    const root = this.workspace.root;
    return root && path.startsWith(root + "/") ? path.slice(root.length + 1) : path;
  }

  // ------------------------------------------------------------ settings

  setPref<K extends keyof Prefs>(key: K, value: Prefs[K]) {
    this.prefs = { ...this.prefs, [key]: value };
    this.savePrefs();
    if (key === "showWordCount") this.refreshDerived();
    if (key === "autoSave" && value) for (const doc of this.docs) if (doc.dirty) this.scheduleAutosave(doc);
    this.emit();
  }

  savePrefs() {
    clearTimeout(this.prefsTimer);
    this.prefsTimer = window.setTimeout(() => void this.backend.savePrefs(JSON.stringify(this.prefs)), 200);
  }

  setZoom(zoom: number) {
    this.ui.zoom = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, Math.round(zoom * 10) / 10));
    this.emit();
  }

  toggle(key: "focusMode" | "quickOpen" | "settings" | "tabSearch") {
    this.ui[key] = !this.ui[key];
    this.emit();
  }

  toggleTOC() {
    const doc = this.active;
    if (!doc) return;
    doc.showTOC = !doc.showTOC;
    this.emit();
  }

  // -------------------------------------------------------------- window

  syncWindow() {
    const doc = this.active;
    this.backend.setTitle(doc ? this.title(doc) : "Vireo");
    this.backend.setDocumentEdited(!!doc?.dirty);
    this.backend.setRepresentedFile(doc?.path ?? null);
  }

  updateWatch() {
    const files = this.docs.map((d) => d.path).filter((p): p is string => !!p);
    void this.backend.watch(files, this.workspace.root);
  }

  async alert(title: string, error: unknown) {
    await this.backend.ask(errorText(error), { title, buttons: ["OK"] });
  }
}

function errorText(e: unknown): string {
  if (typeof e === "string") return e;
  if (e instanceof Error) return e.message;
  return String(e);
}

export function countWords(text: string): WordCount {
  const words = text.match(/[\p{L}\p{N}][\p{L}\p{N}'’_-]*/gu);
  return { words: words?.length ?? 0, characters: text.length };
}
