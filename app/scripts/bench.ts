// Runs the in-page bench in headless browsers. Headless numbers show trends
// only; the Tauri run in WKWebView is the one that decides.
// Usage: bun scripts/bench.ts [webkit|chromium ...]
import { chromium, webkit } from "playwright";
import { writeFileSync, mkdirSync } from "node:fs";

const engines = process.argv.slice(2);
const wanted = engines.length ? engines : ["webkit", "chromium"];
mkdirSync("results", { recursive: true });

for (const name of wanted) {
  const browser = await (name === "chromium" ? chromium : webkit).launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 }, deviceScaleFactor: 2 });
  page.on("pageerror", (e) => console.error("pageerror:", e.message));
  await page.goto("http://localhost:1420/");
  await page.waitForFunction(() => (window as any).__vireo);
  await page.evaluate(() => (window as any).__vireo.bench());
  const text = await page.locator("#results").textContent();
  console.log(`\n=== ${name} ===\n${text}`);
  writeFileSync(`results/bench-${name}.txt`, text ?? "");
  await browser.close();
}
