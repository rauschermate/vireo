import { EditorView } from "@codemirror/view";
import { useEffect, useLayoutEffect, useRef } from "react";
import { Outline, QuickOpen, Settings, WordCount } from "./Panels";
import { Sidebar, SidebarToggle } from "./Sidebar";
import { TabBar } from "./TabBar";
import { ContextMenuHost, useStore } from "./ui";

// The editor lives outside React. React only gives it a parent element; the
// store swaps editor states when the active tab changes.
function EditorPane() {
  const s = useStore();
  const host = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const view = new EditorView({ parent: host.current!, state: s.active?.state });
    s.attachView(view);
    return () => view.destroy();
  }, []);
  useEffect(() => {
    document.documentElement.style.setProperty("--zoom", String(s.ui.zoom));
    s.view?.requestMeasure();
  }, [s.ui.zoom]);
  return <div className="vr-editor" ref={host} />;
}

export function App() {
  const s = useStore();
  const { focusMode } = s.ui;
  const showSidebar = s.prefs.sidebarVisible && !focusMode;
  const showOutline = !!s.active?.showTOC && !focusMode && s.ui.outline.length > 0;

  useEffect(() => {
    const root = document.documentElement;
    if (s.prefs.appearance === "system") delete root.dataset.theme;
    else root.dataset.theme = s.prefs.appearance;
    root.dataset.font = s.prefs.editorFont;
    s.view?.requestMeasure();
  }, [s.prefs.appearance, s.prefs.editorFont]);

  return (
    <div className={"vr-app" + (focusMode ? " is-focus" : "") + (showSidebar ? "" : " no-sidebar")}>
      {showSidebar && <Sidebar />}
      <main className="vr-main">
        {focusMode ? (
          <div className="vr-titlebar-spacer" data-tauri-drag-region />
        ) : (
          <div className="vr-chrome-row" data-tauri-drag-region>
            {!showSidebar && (
              <div className="vr-lights-gap" data-tauri-drag-region>
                <SidebarToggle />
              </div>
            )}
            <TabBar />
          </div>
        )}
        <div className="vr-body">
          <div className="vr-editor-wrap">
            <EditorPane />
            {s.prefs.showWordCount && <WordCount />}
          </div>
          {showOutline && <Outline />}
        </div>
      </main>
      {s.ui.quickOpen && <QuickOpen />}
      {s.ui.settings && <Settings />}
      <ContextMenuHost />
    </div>
  );
}
