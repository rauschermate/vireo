import { EditorView } from "@codemirror/view";
import { FixtureResult, Harness, format, nextPaint, runFixture, stats } from "./bench";
import { createState } from "./editor";
import "./style.css";

const inTauri = "__TAURI_INTERNALS__" in window;
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const status = $("status");
const results = $("results");

const view = new EditorView({ parent: $("editor"), state: createState("") });
let zoom = 1;

async function readFixture(name: string): Promise<string> {
  if (inTauri) {
    const { invoke } = await import("@tauri-apps/api/core");
    const path = await invoke<string>("fixture_path", { name });
    const t0 = performance.now();
    const text = await invoke<string>("read_file", { path });
    ipcMs.push(performance.now() - t0);
    return text;
  }
  return (await fetch(`/${name}`)).text();
}
const ipcMs: number[] = [];

async function open(name: string) {
  const text = await readFixture(name);
  const t0 = performance.now();
  view.setState(createState(text));
  const sync = performance.now() - t0;
  const toPixel = (await nextPaint()) - t0;
  status.textContent = `${name}: open ${toPixel.toFixed(0)} ms`;
  return { bytes: new TextEncoder().encode(text).length, sync, toPixel };
}

function setZoom(value: number) {
  zoom = Math.min(3, Math.max(0.5, Math.round(value * 10) / 10));
  document.documentElement.style.setProperty("--zoom", String(zoom));
  view.requestMeasure();
}

function toggleTheme() {
  const root = document.documentElement;
  const dark = root.dataset.theme ? root.dataset.theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
  root.dataset.theme = dark ? "light" : "dark";
  view.requestMeasure();
}

const harness: Harness = { view: () => view, open, setZoom, toggleTheme };

async function bench(): Promise<FixtureResult[]> {
  results.classList.add("is-open");
  results.textContent = "Running…";
  const out: FixtureResult[] = [];
  for (const name of ["welcome.md", "formatting-dense.md", "single-code-block.md"]) {
    status.textContent = `bench: ${name}`;
    out.push(await runFixture(harness, name));
    setZoom(1);
  }
  const ipc = ipcMs.length ? `\n\nIPC read_file: ${JSON.stringify(stats(ipcMs))}` : "";
  results.textContent = `${navigator.userAgent}\n\n${format(out)}${ipc}`;
  (window as any).__vireoBench = { userAgent: navigator.userAgent, results: out, ipc: ipcMs.length ? stats(ipcMs) : null };
  if (inTauri) {
    const { invoke } = await import("@tauri-apps/api/core");
    await invoke("bench_report", { report: results.textContent });
  }
  return out;
}

// Live keystroke meter for the manual feel test: keydown to the frame after it.
const keyLatency: number[] = [];
view.contentDOM.addEventListener("keydown", () => {
  const t0 = performance.now();
  nextPaint().then((painted) => {
    keyLatency.push(painted - t0);
    if (keyLatency.length > 200) keyLatency.shift();
    const s = stats(keyLatency);
    status.textContent = `key→paint p50 ${s.p50} p95 ${s.p95} ms (n=${s.n}) · zoom ${zoom}`;
  });
});

window.addEventListener(
  "keydown",
  (event) => {
    if (!event.metaKey) return;
    if (event.key === "=" || event.key === "+") setZoom(zoom + 0.1);
    else if (event.key === "-") setZoom(zoom - 0.1);
    else if (event.key === "0") setZoom(1);
    else if (event.shiftKey && event.key.toLowerCase() === "d") toggleTheme();
    else return;
    event.preventDefault();
  },
  true,
);

$<HTMLSelectElement>("fixture").addEventListener("change", (e) => open((e.target as HTMLSelectElement).value));
$("zoom-in").addEventListener("click", () => setZoom(zoom + 0.1));
$("zoom-out").addEventListener("click", () => setZoom(zoom - 0.1));
$("theme").addEventListener("click", toggleTheme);
$("bench").addEventListener("click", () => bench());
results.addEventListener("dblclick", () => results.classList.remove("is-open"));

(window as any).__vireo = { view, open, bench, setZoom, toggleTheme };

const params = new URLSearchParams(location.search);
await open(params.get("file") ?? "welcome.md");
let autoBench = params.has("bench");
if (inTauri) {
  const { invoke } = await import("@tauri-apps/api/core");
  autoBench ||= await invoke<boolean>("bench_mode");
}
if (autoBench) bench();
