import { invoke } from "@tauri-apps/api/core";
import type { Store } from "./store";

// Runs the shell against the real file system in the built app, where the
// browser tests cannot reach: Rust I/O, the watcher, Trash and prefs.
export async function selftest(s: Store, dir: string) {
  const b = s.backend;
  const lines: string[] = [];
  const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
  const log = (line: string) => invoke("selftest_log", { line });
  // Native dialogs would block the run; answer them with the last button.
  b.ask = async (message, { title, buttons }) => {
    await log(`  dialog: ${title} — ${message}`);
    return buttons.length - 1;
  };
  const step = async (name: string, body: () => Promise<boolean | string>) => {
    await log(`… ${name}`);
    try {
      const r = await body();
      lines.push(`${r === true ? "PASS" : "FAIL"} ${name}${typeof r === "string" ? ` — ${r}` : ""}`);
    } catch (e) {
      lines.push(`FAIL ${name} — ${(e as Error)?.message ?? e}`);
    }
  };

  await step("create files and a folder", async () => {
    await b.createDir(`${dir}/Notes`);
    await b.createFile(`${dir}/Alpha.md`, "# Alpha title\n\nFirst.\n");
    await b.createFile(`${dir}/Notes/Beta.md`, "Beta body\n");
    await b.createDir(`${dir}/images-only`);
    await b.createFile(`${dir}/images-only/x.png`, "");
    return true;
  });

  await step("scan: titles, pruning, order", async () => {
    await s.openWorkspace(dir);
    const names = s.workspace.tree.map((n) => n.name).join(",");
    const alpha = s.files().find((f) => f.name === "Alpha.md");
    return names === "Notes,Alpha.md" && alpha?.title === "Alpha title" ? true : `tree ${names}, title ${alpha?.title}`;
  });

  await step("open and autosave", async () => {
    const doc = await s.openPath(`${dir}/Alpha.md`);
    s.view!.dispatch({ changes: { from: s.view!.state.doc.length, insert: "Typed.\n" } });
    await wait(1200);
    const { text } = await b.readText(`${dir}/Alpha.md`);
    return text.endsWith("Typed.\n") && !doc!.dirty ? true : `disk: ${JSON.stringify(text)}`;
  });

  await step("watcher reloads an external change", async () => {
    await b.writeText(`${dir}/Alpha.md`, "# Rewritten outside\n");
    for (let i = 0; i < 30 && s.textOf(s.active!) !== "# Rewritten outside\n"; i++) await wait(100);
    return s.textOf(s.active!) === "# Rewritten outside\n" ? true : `text: ${JSON.stringify(s.textOf(s.active!))}`;
  });

  await step("rename keeps the tab", async () => {
    await s.renameDoc(s.active!, "Gamma");
    const moved = (await b.exists(`${dir}/Gamma.md`)) && !(await b.exists(`${dir}/Alpha.md`));
    return moved && s.active!.path === `${dir}/Gamma.md` ? true : `path ${s.active!.path}`;
  });

  await step("Trash removes the file and its tab", async () => {
    await s.deletePaths([`${dir}/Gamma.md`]);
    return !(await b.exists(`${dir}/Gamma.md`)) && !s.docs.some((d) => d.path?.endsWith("Gamma.md")) ? true : "still there";
  });

  await step("prefs round-trip", async () => {
    s.setPref("showWordCount", true);
    await wait(400);
    const saved = JSON.parse(await b.loadPrefs());
    s.setPref("showWordCount", false);
    await wait(400);
    return saved.showWordCount === true && saved.lastWorkspace === dir ? true : JSON.stringify(saved).slice(0, 200);
  });

  await step("menu bar installed", async () => {
    const { Menu } = await import("@tauri-apps/api/menu");
    const menu = await Menu.default();
    return !!menu ? true : "no menu";
  });

  await step("image resolves relative to the file", async () => {
    await b.createFile(`${dir}/pic.svg`, '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="red"/></svg>');
    await b.createFile(`${dir}/Pic.md`, "![pic](pic.svg)\n\ntext\n");
    await s.openPath(`${dir}/Pic.md`, undefined, false);
    s.view!.dispatch({ selection: { anchor: s.view!.state.doc.length } });
    for (let i = 0; i < 30; i++) {
      const img = document.querySelector<HTMLImageElement>(".cm-md-image");
      if (img?.complete && img.naturalWidth > 0) return true;
      await wait(100);
    }
    const img = document.querySelector<HTMLImageElement>(".cm-md-image");
    return `img ${img ? `${img.src} w=${img.naturalWidth}` : "missing"}`;
  });

  // A real ⌘B from scripts/selftest.sh. Both the menu and the web view see
  // the key; bold must toggle exactly once.
  if (await invoke<boolean>("selftest_keys")) {
    await step("⌘B from the keyboard toggles bold once", async () => {
      await b.createFile(`${dir}/Keys.md`, "word\n");
      await s.openPath(`${dir}/Keys.md`);
      s.view!.focus();
      s.view!.dispatch({ selection: { anchor: 0, head: 4 } });
      await log("KEYS-READY");
      for (let i = 0; i < 100 && s.textOf(s.active!) === "word\n"; i++) await wait(100);
      await wait(500);
      const text = s.textOf(s.active!);
      return text === "**word**\n" ? true : `text ${JSON.stringify(text)}`;
    });
  }

  s.closeWorkspace();
  await invoke("selftest_report", { report: lines.join("\n") });
}
