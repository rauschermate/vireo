// End-to-end checks of the shell in headless WebKit, against the in-memory
// file system. Needs the dev server: `bun run dev`, then `bun scripts/e2e.ts`.
import { webkit, Page } from "playwright";

const ROOT = "/Users/demo/Notes";
const results: { name: string; ok: boolean; detail?: string }[] = [];

async function fresh(): Promise<Page> {
  const browser = await webkit.launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  page.on("pageerror", (e) => console.error("  pageerror:", e.message));
  await page.addInitScript(() => localStorage.clear());
  await page.goto("http://localhost:1420/");
  await page.waitForFunction(() => (window as any).__store?.docs.length > 0);
  await page.waitForTimeout(200);
  (page as any).__browser = browser;
  return page;
}

async function check(name: string, body: (p: Page) => Promise<void>) {
  const page = await fresh();
  try {
    await body(page);
    results.push({ name, ok: true });
  } catch (e) {
    results.push({ name, ok: false, detail: (e as Error).message });
  } finally {
    await (page as any).__browser.close();
  }
}

function expect(cond: unknown, what: string) {
  if (!cond) throw new Error(what);
}

const store = <T>(p: Page, fn: string) => p.evaluate(`(() => { const s = window.__store, h = window.__host; ${fn} })()`) as Promise<T>;
const disk = (p: Page, path: string) => store<string | null>(p, `return h.files.get(${JSON.stringify(path)})?.text ?? null;`);
const activeText = (p: Page) => store<string>(p, "return s.textOf(s.active);");
const activeTitle = (p: Page) => store<string>(p, "return s.title(s.active);");
const tabs = (p: Page) => store<string[]>(p, "return s.docs.map((d) => s.title(d));");
const sidebarRow = (p: Page, label: string) => p.locator(".vr-tree-row", { hasText: label }).first();
const typeInEditor = async (p: Page, text: string) => {
  await p.locator(".vr-editor .cm-content").first().click();
  await p.keyboard.press("Meta+ArrowDown");
  await p.keyboard.type(text);
};

await check("open a file from the sidebar", async (p) => {
  await sidebarRow(p, "Lists").click();
  await p.waitForTimeout(150);
  expect((await tabs(p)).join() === "Welcome,Lists", `tabs: ${await tabs(p)}`);
  expect((await activeText(p)).startsWith("# Lists"), "Lists content");
});

await check("autosave writes 0.5 s after typing", async (p) => {
  await sidebarRow(p, "Lists").click();
  await typeInEditor(p, "\nautosaved line");
  await p.waitForTimeout(250);
  expect(!(await disk(p, `${ROOT}/Lists.md`))!.includes("autosaved line"), "saved too early");
  await p.waitForTimeout(600);
  expect((await disk(p, `${ROOT}/Lists.md`))!.includes("autosaved line"), "not saved after 0.5 s");
  expect(!(await store<boolean>(p, "return s.active.dirty;")), "still dirty");
});

await check("a clean tab reloads an external change", async (p) => {
  await sidebarRow(p, "Lists").click();
  await store(p, `h.externalWrite("${ROOT}/Lists.md", "# Changed outside\\n");`);
  await p.waitForTimeout(200);
  expect((await activeText(p)) === "# Changed outside\n", `text: ${await activeText(p)}`);
});

await check("a dirty tab asks about an external change; Reload Disk", async (p) => {
  await store(p, "s.setPref('autoSave', false);");
  await sidebarRow(p, "Lists").click();
  await typeInEditor(p, "\nlocal edit");
  await store(p, `h.askAnswers.push(1); h.externalWrite("${ROOT}/Lists.md", "# Disk wins\\n");`);
  await p.waitForTimeout(250);
  const asked = await store<string[]>(p, "return h.asked;");
  expect(asked.some((q) => q.includes("did not overwrite the newer disk version")), `asked: ${asked}`);
  expect((await activeText(p)) === "# Disk wins\n", "not reloaded");
  expect(!(await store<boolean>(p, "return s.active.dirty;")), "still dirty");
});

await check("Keep Mine overwrites the newer disk version", async (p) => {
  await store(p, "s.setPref('autoSave', false);");
  await sidebarRow(p, "Lists").click();
  await typeInEditor(p, "\nmine");
  await store(p, `h.askAnswers.push(0); h.externalWrite("${ROOT}/Lists.md", "# Theirs\\n");`);
  await p.waitForTimeout(300);
  expect((await disk(p, `${ROOT}/Lists.md`))!.endsWith("mine"), "disk does not hold my text");
});

await check("closing an unsaved tab asks; Don't Save closes it", async (p) => {
  await store(p, "s.setPref('autoSave', false);");
  await sidebarRow(p, "Lists").click();
  await typeInEditor(p, "\nunsaved");
  await store(p, "h.askAnswers.push(1);");
  await p.keyboard.press("Meta+w");
  await p.waitForTimeout(200);
  const asked = await store<string[]>(p, "return h.asked;");
  expect(asked.some((q) => q.includes("Your changes will be lost")), `asked: ${asked}`);
  expect(!(await tabs(p)).includes("Lists"), "tab still open");
  expect(!(await disk(p, `${ROOT}/Lists.md`))!.includes("unsaved"), "saved anyway");
});

await check("⌘S saves when autosave is off; the window shows the edited dot", async (p) => {
  await store(p, "s.setPref('autoSave', false);");
  await sidebarRow(p, "Lists").click();
  await typeInEditor(p, "\nmanual");
  expect(await store<boolean>(p, "return h.edited;"), "no edited dot");
  await p.keyboard.press("Meta+s");
  await p.waitForTimeout(150);
  expect((await disk(p, `${ROOT}/Lists.md`))!.includes("manual"), "not saved");
  expect(!(await store<boolean>(p, "return h.edited;")), "edited dot stays");
});

await check("⌘N creates Untitled.md and renames it inline", async (p) => {
  await sidebarRow(p, "Lists").click();
  await p.keyboard.press("Meta+n");
  await p.waitForTimeout(300);
  expect((await disk(p, `${ROOT}/Untitled.md`)) === "", "no Untitled.md");
  expect((await activeTitle(p)) === "Untitled", `title ${await activeTitle(p)}`);
  await p.keyboard.type("Fresh Note");
  await p.keyboard.press("Enter");
  await p.waitForTimeout(500);
  expect((await disk(p, `${ROOT}/Fresh Note.md`)) === "", "not renamed on disk");
  expect((await activeTitle(p)) === "Fresh Note", `tab title ${await activeTitle(p)}`);
});

await check("rename a tab from its context menu", async (p) => {
  await sidebarRow(p, "Lists").click();
  await p.locator(".vr-tab", { hasText: "Lists" }).click({ button: "right" });
  await p.locator(".vr-menu button", { hasText: "Rename…" }).click();
  await p.keyboard.press("Meta+a");
  await p.keyboard.type("Checklists");
  await p.keyboard.press("Enter");
  await p.waitForTimeout(300);
  expect((await disk(p, `${ROOT}/Checklists.md`)) !== null && (await disk(p, `${ROOT}/Lists.md`)) === null, "not renamed");
  expect((await activeTitle(p)) === "Checklists", `title ${await activeTitle(p)}`);
});

await check("⌘P opens a file by name", async (p) => {
  await p.keyboard.press("Meta+p");
  await p.keyboard.type("road");
  await p.keyboard.press("Enter");
  await p.waitForTimeout(200);
  expect((await activeTitle(p)) === "Roadmap", `title ${await activeTitle(p)}`);
});

await check("pin a file", async (p) => {
  await sidebarRow(p, "Lists").click({ button: "right" });
  await p.locator(".vr-menu button", { hasText: "Pin" }).click();
  await p.waitForTimeout(100);
  expect((await p.locator(".vr-section h3", { hasText: "Pinned" }).count()) === 1, "no Pinned section");
});

await check("delete moves to the Trash and closes the tab", async (p) => {
  await sidebarRow(p, "Lists").click();
  await sidebarRow(p, "Lists").click({ button: "right" });
  await p.locator(".vr-menu button", { hasText: "Delete" }).click();
  await p.waitForTimeout(500);
  expect((await disk(p, `${ROOT}/Lists.md`)) === null, "file still there");
  expect(!(await tabs(p)).includes("Lists"), "tab still open");
});

await check("deleting several items asks first", async (p) => {
  await sidebarRow(p, "Lists").click();
  await sidebarRow(p, "Welcome to Vireo").click({ modifiers: ["Meta"] });
  await store(p, "h.askAnswers.push(1);");
  await sidebarRow(p, "Lists").click({ button: "right" });
  await p.locator(".vr-menu button", { hasText: "Delete 2 items" }).click();
  await p.waitForTimeout(200);
  const asked = await store<string[]>(p, "return h.asked;");
  expect(asked.includes(""), "no question"); // the title carries the question
  expect((await disk(p, `${ROOT}/Lists.md`)) !== null, "deleted despite Cancel");
});

await check("⌘\\ hides the sidebar; focus mode hides the chrome", async (p) => {
  await p.keyboard.press("Meta+Backslash");
  await p.waitForTimeout(100);
  expect((await p.locator(".vr-sidebar").count()) === 0, "sidebar visible");
  await p.keyboard.press("Meta+Backslash");
  await p.keyboard.press("Meta+Shift+Period");
  await p.waitForTimeout(100);
  expect((await p.locator(".vr-sidebar, .vr-tabbar").count()) === 0, "chrome visible in focus mode");
});

await check("the outline lists headings and jumps to one", async (p) => {
  await p.keyboard.press("Meta+Alt+Backslash");
  await p.waitForTimeout(400);
  const items = await p.locator(".vr-outline-item").allTextContents();
  expect(items.includes("The usual suspects"), `outline: ${items}`);
  await p.locator(".vr-outline-item", { hasText: "And a table" }).click();
  const line = await store<string>(p, "return s.view.state.doc.lineAt(s.view.state.selection.main.head).text;");
  expect(line.includes("And a table"), `caret on: ${line}`);
});

await check("zoom steps by 0.1 within 0.6–3.0", async (p) => {
  await p.keyboard.press("Meta+Equal");
  expect((await store<number>(p, "return s.ui.zoom;")) === 1.1, "zoom in");
  for (let i = 0; i < 10; i++) await p.keyboard.press("Meta+Minus");
  expect((await store<number>(p, "return s.ui.zoom;")) === 0.6, "zoom floor");
});

await check("a relative link opens the file at the anchor", async (p) => {
  await sidebarRow(p, "Lists").click();
  await store(p, "s.followLink(s.active, 'Projects/Roadmap.md#later');");
  await p.waitForTimeout(300);
  expect((await activeTitle(p)) === "Roadmap", `title ${await activeTitle(p)}`);
  const line = await store<string>(p, "return s.view.state.doc.lineAt(s.view.state.selection.main.head).text;");
  expect(line === "## Later", `caret on: ${line}`);
  await store(p, "s.followLink(s.active, 'https://vireo.md');");
  expect((await store<string[]>(p, "return h.opened;")).includes("https://vireo.md"), "URL not opened");
});

await check("settings: word count badge", async (p) => {
  await p.keyboard.press("Meta+Comma");
  await p.locator(".vr-setting label", { hasText: "Show word count" }).click();
  await p.keyboard.press("Escape");
  await p.waitForTimeout(400);
  const badge = await p.locator(".vr-word-count").textContent();
  expect(/\d+ words · \d+ characters/.test(badge ?? ""), `badge: ${badge}`);
});

await check("recents appear from 10 files, 3 at a time", async (p) => {
  await store(p, `for (let i = 0; i < 6; i++) h.externalWrite("${ROOT}/Extra " + i + ".md", "# Extra " + i);`);
  await p.waitForTimeout(600);
  const section = p.locator(".vr-section", { has: p.locator("h3", { hasText: "Recents" }) });
  expect((await section.count()) === 1, "no Recents section");
  expect((await section.locator(".vr-tree-row").count()) === 3, "not 3 rows");
});

await check("files opened from Finder replace the empty first tab", async (p) => {
  await store(p, "s.closeTab(s.docs[0].id);");
  await p.waitForTimeout(100);
  expect((await tabs(p)).join() === "Untitled", `tabs ${await tabs(p)}`);
  await store(p, `h.openFiles(["${ROOT}/Journal/2026-10-27.md"]);`);
  await p.waitForTimeout(200);
  expect((await tabs(p)).join() === "2026-10-27", `tabs ${await tabs(p)}`);
});

const failed = results.filter((r) => !r.ok);
for (const r of results) console.log(`${r.ok ? "✓" : "✗"} ${r.name}${r.detail ? ` — ${r.detail}` : ""}`);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);
