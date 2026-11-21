// Renders the app (with the in-memory file system) in headless WebKit.
// Usage: bun scripts/shot-app.ts <out.png> [--dark] [--width 1200] [--height 800] [--eval "js"]
import { webkit } from "playwright";

const args = process.argv.slice(2);
const out = args[0] ?? "results/app.png";
const opt = (flag: string) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};
const browser = await webkit.launch();
const page = await browser.newPage({
  viewport: { width: Number(opt("--width") ?? 1200), height: Number(opt("--height") ?? 800) },
  colorScheme: args.includes("--dark") ? "dark" : "light",
  deviceScaleFactor: 2,
});
page.on("pageerror", (e) => console.error("pageerror:", e.message));
page.on("console", (m) => m.type() === "error" && console.error("console:", m.text()));
await page.goto("http://localhost:1420/");
await page.waitForFunction(() => (window as any).__store?.docs.length > 0);
await page.waitForTimeout(400);
const script = opt("--eval");
if (script) {
  await page.evaluate(script);
  await page.waitForTimeout(400);
}
await page.screenshot({ path: out });
await browser.close();
console.log(out);
