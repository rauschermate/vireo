# Vireo (Tauri)

The cross-platform rewrite of Vireo: Tauri v2, CodeMirror 6, and React for the chrome. It keeps Vireo's rules. The raw markdown string is the only source of truth, syntax stays hidden until the caret touches it, and a save writes the string back unchanged.

The Swift app in the repository root stays the shipping app until this one replaces it. This app uses its own bundle id (`com.materauscher.vireo.next`, "Vireo Next"), so both run side by side.

## Commands

```sh
bun install
./scripts/fixtures.sh                 # benchmark fixtures + samples, served by the dev server
bun run dev                           # http://localhost:1420 — the app on an in-memory file system
bunx tauri build --bundles app        # src-tauri/target/release/bundle/macos/Vireo Next.app

bun test                              # editor invariants, formatting, tables, app logic
bun run e2e                           # 20 shell flows in headless WebKit (needs `bun run dev`)
bun run selftest                      # the built app against a temp folder, with a real ⌘B
(cd src-tauri && cargo test)          # file I/O, scan, Trash, watcher paths
```

- `bun scripts/shot-app.ts out.png [--dark] [--eval "js"]` renders the app to a PNG.
- `bench.html` is the performance harness. `bun scripts/bench.ts webkit` runs it headless; `VIREO_BENCH=1` runs it inside the built app.
- `FUZZ_SEEDS=3000 FUZZ_STEPS=300 bun test` runs the long incremental-parse fuzz.

## Layout

| Path | What |
|---|---|
| `src/editor/` | The editor core: live preview, block field, tables, formatting, find. No app knowledge; per-document hooks come in through `host.ts`. |
| `src/app/` | The shell. `store.ts` owns documents, saving, the workspace and prefs, outside React. `commands.ts` is the one registry for menus and shortcuts. `backend.ts` is the host interface, with a Tauri and an in-memory implementation. |
| `src/bench/` | The performance harness behind `bench.html`. |
| `src-tauri/` | Rust: atomic save, workspace scan, file watcher, Trash and Finder actions, prefs, files opened from Finder, window state. |

## Rules that are easy to break

- **Incremental equals full.** The block field and the parser must give the same result as a fresh parse after any edit. `test/blocks.test.ts` fuzzes this. `src/editor/markdown.ts` works around two `@lezer/markdown` bugs that break it.
- **Nothing per keystroke may scan the document.** Decorations stay in the viewport; the block field rescans only what an edit can change.
- **The store never emits on plain keystrokes**, only when a tab turns dirty or clean. React re-renders the chrome, not the editor.
- **Saving re-reads the disk first.** If the disk changed under unsaved edits, the user picks Keep Mine or Reload Disk. Never overwrite silently.
- **A shortcut can reach both the menu and the web view.** `runCommand` drops the second delivery; `scripts/selftest.sh` checks it with a real key press.

Phase 1 results and the reasoning behind the design are in `docs/spike-findings.md`.
