import { cursorCharRight, cursorLineDown } from "@codemirror/commands";
import { EditorSelection } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { blockStats } from "./blocks";

export interface Stats {
  n: number;
  p50: number;
  p95: number;
  max: number;
}

export interface OpWork {
  work: Stats;
  latency: Stats;
}

export interface FixtureResult {
  fixture: string;
  bytes: number;
  openSync: number;
  openToPixel: number;
  typing: OpWork;
  blockScanMs: number;
  caretRight: OpWork;
  caretDown: OpWork;
  zoom: OpWork;
  theme: OpWork;
  scrollSmooth: Stats & { long: number };
  scrollFlick: Stats & { long: number };
}

export interface Harness {
  view: () => EditorView;
  open: (name: string) => Promise<{ bytes: number; sync: number; toPixel: number }>;
  setZoom: (zoom: number) => void;
  toggleTheme: () => void;
}

export function stats(values: number[]): Stats {
  const sorted = [...values].sort((a, b) => a - b);
  const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] ?? 0;
  return { n: values.length, p50: round(at(0.5)), p95: round(at(0.95)), max: round(sorted[sorted.length - 1] ?? 0) };
}

const round = (v: number) => Math.round(v * 100) / 100;

const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));

// A message posted from a rAF callback is delivered after that frame paints.
export function nextPaint(): Promise<number> {
  return new Promise((resolve) =>
    requestAnimationFrame(() => {
      const channel = new MessageChannel();
      channel.port1.onmessage = () => resolve(performance.now());
      channel.port2.postMessage(null);
    }),
  );
}

// CodeMirror updates the DOM inside dispatch and measures in its own rAF
// callback, which runs before ours in the same frame. Work is the sync part
// plus everything that ran in that frame before our callback.
async function measure(op: () => void) {
  const t0 = performance.now();
  op();
  const t1 = performance.now();
  const frameStart = await frame();
  const t2 = performance.now();
  const painted = await nextPaint();
  return { work: t1 - t0 + Math.max(0, t2 - frameStart), latency: painted - t0 };
}

async function repeat(count: number, op: (i: number) => void): Promise<OpWork> {
  const work: number[] = [];
  const latency: number[] = [];
  for (let i = 0; i < count; i++) {
    const m = await measure(() => op(i));
    work.push(m.work);
    latency.push(m.latency);
  }
  return { work: stats(work), latency: stats(latency) };
}

async function scroll(view: EditorView, step: number, frames: number) {
  const scroller = view.scrollDOM;
  scroller.scrollTop = 0;
  await nextPaint();
  const deltas: number[] = [];
  let last = await frame();
  for (let i = 0; i < frames; i++) {
    scroller.scrollTop += step;
    const now = await frame();
    deltas.push(now - last);
    last = now;
  }
  const s = stats(deltas);
  // A frame counts as long if it took more than 1.5 of the median interval,
  // which works on both 60 Hz and 120 Hz displays.
  return { ...s, long: deltas.filter((d) => d > s.p50 * 1.5 + 2).length };
}

function middleParagraphLine(view: EditorView): number {
  const doc = view.state.doc;
  for (let n = Math.floor(doc.lines / 2); n <= doc.lines; n++) {
    const text = doc.line(n).text;
    if (text.length > 40 && /^[A-Za-z]/.test(text)) return n;
  }
  return 1;
}

export async function runFixture(h: Harness, name: string): Promise<FixtureResult> {
  const opens: { sync: number; toPixel: number; bytes: number }[] = [];
  for (let i = 0; i < 3; i++) opens.push(await h.open(name));
  const open = opens.sort((a, b) => a.toPixel - b.toPixel)[1];
  const view = h.view();
  view.focus();

  const lineNo = middleParagraphLine(view);
  const line = view.state.doc.line(lineNo);
  view.dispatch({ selection: { anchor: line.to }, scrollIntoView: true });
  await nextPaint();
  const scans: number[] = [];
  const typing = await repeat(100, () => {
    view.dispatch(view.state.replaceSelection("a"), { userEvent: "input.type", scrollIntoView: true });
    scans.push(blockStats.lastScanMs);
  });

  view.dispatch({ selection: EditorSelection.cursor(line.from), scrollIntoView: true });
  await nextPaint();
  const caretRight = await repeat(200, () => cursorCharRight(view));
  view.dispatch({ selection: EditorSelection.cursor(line.from), scrollIntoView: true });
  await nextPaint();
  const caretDown = await repeat(100, () => cursorLineDown(view));

  const zooms = [1.1, 1.2, 1.3, 1.2, 1.1, 1.0];
  const zoom = await repeat(zooms.length, (i) => h.setZoom(zooms[i]));
  const theme = await repeat(4, () => h.toggleTheme());

  view.contentDOM.blur();
  const scrollSmooth = await scroll(view, 40, 120);
  const scrollFlick = await scroll(view, Math.max(2000, view.contentHeight / 60), 60);

  return {
    fixture: name,
    bytes: open.bytes,
    openSync: round(open.sync),
    openToPixel: round(open.toPixel),
    typing,
    blockScanMs: stats(scans).p95,
    caretRight,
    caretDown,
    zoom,
    theme,
    scrollSmooth,
    scrollFlick,
  };
}

export function format(results: FixtureResult[]): string {
  const s = (o: OpWork) => `work p50 ${o.work.p50} p95 ${o.work.p95} max ${o.work.max} | latency p50 ${o.latency.p50} p95 ${o.latency.p95}`;
  const f = (o: Stats & { long: number }) => `frame p50 ${o.p50} p95 ${o.p95} max ${o.max} | long ${o.long}/${o.n}`;
  return results
    .map((r) =>
      [
        `${r.fixture} (${(r.bytes / 1048576).toFixed(2)} MiB)`,
        `  open           sync ${r.openSync} ms | to pixel ${r.openToPixel} ms`,
        `  typing         ${s(r.typing)}   (block scan p95 ${r.blockScanMs})`,
        `  caret right    ${s(r.caretRight)}`,
        `  caret down     ${s(r.caretDown)}`,
        `  zoom step      ${s(r.zoom)}`,
        `  theme toggle   ${s(r.theme)}`,
        `  scroll smooth  ${f(r.scrollSmooth)}`,
        `  scroll flick   ${f(r.scrollFlick)}`,
      ].join("\n"),
    )
    .join("\n\n");
}
