// Everything the app needs from the host. The Tauri backend talks to Rust;
// the memory backend runs the same app in a plain browser for tests.

export interface FileText {
  text: string;
  mtime: number;
}

export interface Node {
  name: string;
  path: string;
  dir: boolean;
  // Front matter title or leading H1; files only.
  title: string | null;
  mtime: number;
  children: Node[];
}

export interface Backend {
  readonly kind: "tauri" | "memory";
  readText(path: string): Promise<FileText>;
  writeText(path: string, text: string): Promise<number>;
  scanWorkspace(root: string): Promise<Node[]>;
  createFile(path: string, text: string): Promise<void>;
  createDir(path: string): Promise<void>;
  rename(from: string, to: string): Promise<void>;
  trash(path: string): Promise<void>;
  reveal(path: string): Promise<void>;
  openExternal(path: string): Promise<void>;
  openInTerminal(path: string): Promise<void>;
  exists(path: string): Promise<boolean>;
  loadPrefs(): Promise<string>;
  savePrefs(json: string): Promise<void>;
  watch(files: string[], root: string | null): Promise<void>;
  onFsChange(cb: (paths: string[]) => void): void;
  onMenu(cb: (id: string) => void): void;
  onOpenFiles(cb: (paths: string[]) => void): void;
  openDialog(options: { directory: boolean; multiple: boolean; images?: boolean }): Promise<string[]>;
  saveDialog(defaultPath: string): Promise<string | null>;
  ask(message: string, options: { title: string; buttons: string[] }): Promise<number>;
  openUrl(url: string): Promise<void>;
  fileSrc(path: string): string;
  setTitle(title: string): void;
  setDocumentEdited(edited: boolean): void;
  setRepresentedFile(path: string | null): void;
  quit(): Promise<void>;
  onCloseRequested(cb: () => Promise<boolean>): void;
}

export async function createBackend(): Promise<Backend> {
  if ("__TAURI_INTERNALS__" in window) return (await import("./tauriBackend")).tauriBackend();
  return (await import("./memoryBackend")).memoryBackend();
}
