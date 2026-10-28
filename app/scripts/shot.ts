// Renders the spike in headless WebKit (the engine behind WKWebView) to PNG.
// Usage: bun scripts/shot.ts <out.png> [--dark] [--file name.md] [--caret <pos>] [--width 900]
import { webkit } from "playwright";

const args = process.argv.slice(2);
const out = args[0] ?? "results/shot.png";
const opt = (flag: string) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};

const browser = await webkit.launch();
const page = await browser.newPage({
  viewport: { width: Number(opt("--width") ?? 900), height: Number(opt("--height") ?? 1400) },
  colorScheme: args.includes("--dark") ? "dark" : "light",
  deviceScaleFactor: 2,
});
page.on("pageerror", (e) => console.error("pageerror:", e.message));
page.on("console", (m) => m.type() === "error" && console.error("console:", m.text()));
await page.goto(`http://localhost:1420/?file=${opt("--file") ?? "welcome.md"}`);
await page.waitForFunction(() => (window as any).__vireo);
await page.waitForTimeout(300);
const caret = opt("--caret");
if (caret) {
  await page.evaluate((pos) => {
    const v = (window as any).__vireo.view;
    v.focus();
    v.dispatch({ selection: { anchor: Number(pos) } });
  }, caret);
  await page.waitForTimeout(100);
}
const scroll = opt("--scroll");
if (scroll) {
  await page.evaluate((pos) => {
    const v = (window as any).__vireo.view;
    v.scrollDOM.scrollTop = v.lineBlockAt(Number(pos)).top;
  }, scroll);
  await page.waitForTimeout(1000);
}
await page.screenshot({ path: out });
await browser.close();
console.log(out);
