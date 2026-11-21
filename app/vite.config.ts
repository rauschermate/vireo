import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

export default defineConfig(({ command }) => ({
  plugins: [react()],
  // The dev server serves the fixtures. The Tauri build reads them from disk.
  publicDir: command === "build" ? false : "fixtures",
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: {
    target: "safari16",
    rollupOptions: { input: { main: resolve(__dirname, "index.html"), bench: resolve(__dirname, "bench.html") } },
  },
}));
