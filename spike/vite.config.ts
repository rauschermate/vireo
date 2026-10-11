import { defineConfig } from "vite";

export default defineConfig({
  publicDir: "fixtures",
  clearScreen: false,
  server: { port: 1420, strictPort: true },
});
