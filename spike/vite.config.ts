import { defineConfig } from "vite";

export default defineConfig(({ command }) => ({
  // The dev server serves the fixtures. The Tauri build reads them from disk.
  publicDir: command === "build" ? false : "fixtures",
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: { target: "safari16" },
}));
