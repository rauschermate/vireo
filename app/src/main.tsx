import { createRoot } from "react-dom/client";
import { App } from "./app/App";
import { createBackend } from "./app/backend";
import { installKeyboard } from "./app/commands";
import { Store } from "./app/store";
import { StoreContext } from "./app/ui";
import welcome from "../samples/welcome.md?raw";
import "./editor/editor.css";
import "./app/app.css";

async function start() {
  if ("__TAURI_INTERNALS__" in window) {
    const { invoke } = await import("@tauri-apps/api/core");
    // VIREO_BENCH runs the performance harness instead of the app.
    if (await invoke<boolean>("bench_mode")) return void location.replace("/bench.html");
  }
  const backend = await createBackend();
  const store = await Store.create(backend);
  (window as any).__store = store;

  createRoot(document.getElementById("root")!).render(
    <StoreContext.Provider value={store}>
      <App />
    </StoreContext.Provider>,
  );

  installKeyboard(store);
  if (backend.kind === "tauri") (await import("./app/menu")).installMenu(store);
  backend.onCloseRequested(() => store.closeAll());

  // Session start, as in Vireo: the last workspace comes back; tabs do not.
  const pending: string[] = [];
  let ready = false;
  backend.onOpenFiles((paths) => (ready ? void store.openPaths(paths) : pending.push(...paths)));
  if (store.prefs.lastWorkspace) await store.openWorkspace(store.prefs.lastWorkspace, false);
  if (store.workspace.status === "error") store.closeWorkspace();
  ready = true;
  if (pending.length) await store.openPaths(pending);
  if (store.docs.length === 0) {
    if (!store.prefs.hasOpenedWelcome) {
      store.openWelcome(welcome);
      store.setPref("hasOpenedWelcome", true);
    } else store.newTab();
  }
  store.syncWindow();
  store.focusEditor();
}

void start();
