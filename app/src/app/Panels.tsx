import { useEffect, useMemo, useRef, useState } from "react";
import type { Node } from "./backend";
import { fuzzyMatch } from "./fuzzy";
import { isMarkdown, stem } from "./paths";
import type { Prefs } from "./prefs";
import { Icon, useStore } from "./ui";

export function Outline() {
  const s = useStore();
  return (
    <aside className="vr-outline" aria-label="Table of contents">
      <div className="vr-outline-head">
        <button type="button" className="vr-chrome-button vr-outline-close" title="Hide table of contents" aria-label="Hide table of contents" onClick={() => s.toggleTOC()}>
          <Icon name="close" />
        </button>
      </div>
      <nav className="vr-outline-list">
        {s.ui.outline.map((h, i) => (
          <button
            type="button"
            key={`${h.from}-${i}`}
            className={"vr-outline-item" + (i === s.ui.currentHeading ? " is-current" : "")}
            style={{ paddingLeft: 12 + (h.level - 1) * 12 }}
            onClick={() => s.scrollTo(h.from)}
          >
            {h.text || "Untitled"}
          </button>
        ))}
      </nav>
    </aside>
  );
}

const RECENT_COUNT = 20;
const MAX_RESULTS = 50;

// Vireo's tiers: a name or title prefix, then a substring, then a path
// substring. A fuzzy subsequence match comes last.
function tier(q: string, s: { label: string; name: string; rel: string }): number | null {
  const label = s.label.toLowerCase();
  const name = s.name.toLowerCase();
  const rel = s.rel.toLowerCase();
  if (label.startsWith(q) || name.startsWith(q)) return 0;
  if (label.includes(q) || name.includes(q)) return 1;
  if (rel.includes(q)) return 2;
  if (fuzzyMatch(q, name) || fuzzyMatch(q, label)) return 3;
  return null;
}

export function QuickOpen() {
  const s = useStore();
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const list = useRef<HTMLDivElement>(null);
  const candidates = useMemo(
    () => s.files().map((f: Node) => ({ path: f.path, label: s.label(f), name: isMarkdown(f.name) ? stem(f.name) : f.name, rel: s.relativePath(f.path), mtime: f.mtime })),
    [s.workspace.tree, s.prefs.fileLabel],
  );
  const results = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return [...candidates].sort((a, b) => b.mtime - a.mtime).slice(0, RECENT_COUNT);
    return candidates
      .map((c) => ({ c, t: tier(q, c) }))
      .filter((x): x is { c: (typeof candidates)[number]; t: number } => x.t !== null)
      .sort((a, b) => a.t - b.t || b.c.mtime - a.c.mtime)
      .slice(0, MAX_RESULTS)
      .map((x) => x.c);
  }, [query, candidates]);

  useEffect(() => setIndex(0), [query]);
  useEffect(() => {
    list.current?.children[index]?.scrollIntoView({ block: "nearest" });
  }, [index]);

  const close = () => {
    s.ui.quickOpen = false;
    s.emit();
  };
  const open = (path: string) => {
    close();
    void s.openPath(path);
  };

  return (
    <div className="vr-overlay" onMouseDown={(e) => e.target === e.currentTarget && close()}>
      <div className="vr-quick-open" role="dialog" aria-label="Search files">
        <input
          autoFocus
          placeholder="Search files"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") close();
            else if (e.key === "ArrowDown") {
              e.preventDefault();
              setIndex((i) => (results.length ? (i + 1) % results.length : 0));
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setIndex((i) => (results.length ? (i - 1 + results.length) % results.length : 0));
            } else if (e.key === "Enter" && results[index]) open(results[index].path);
          }}
        />
        <div className="vr-quick-list" ref={list}>
          {results.length === 0 && <div className="vr-empty">{candidates.length === 0 ? "No files" : "No results"}</div>}
          {results.map((r, i) => (
            <button type="button" key={r.path} className={"vr-quick-row" + (i === index ? " is-active" : "")} onMouseMove={() => setIndex(i)} onClick={() => open(r.path)}>
              <span className="vr-quick-title">{r.label}</span>
              <span className="vr-quick-path">{r.rel}</span>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

function Choice<K extends keyof Prefs>({ pref, options }: { pref: K; options: [Prefs[K], string][] }) {
  const s = useStore();
  return (
    <select value={String(s.prefs[pref])} onChange={(e) => s.setPref(pref, options.find(([v]) => String(v) === e.target.value)![0])}>
      {options.map(([v, label]) => (
        <option key={String(v)} value={String(v)}>
          {label}
        </option>
      ))}
    </select>
  );
}

function Toggle({ pref }: { pref: "autoSave" | "showWordCount" }) {
  const s = useStore();
  return <input type="checkbox" checked={s.prefs[pref]} onChange={(e) => s.setPref(pref, e.target.checked)} />;
}

export function Settings() {
  const s = useStore();
  const close = () => {
    s.ui.settings = false;
    s.emit();
    s.focusEditor();
  };
  useEffect(() => {
    const key = (e: KeyboardEvent) => e.key === "Escape" && close();
    addEventListener("keydown", key);
    return () => removeEventListener("keydown", key);
  }, []);
  return (
    <div className="vr-overlay" onMouseDown={(e) => e.target === e.currentTarget && close()}>
      <div className="vr-settings" role="dialog" aria-label="Settings">
        <header>
          <h2>Settings</h2>
          <button type="button" className="vr-chrome-button" aria-label="Close settings" onClick={close}>
            <Icon name="close" />
          </button>
        </header>
        <div className="vr-setting">
          <label>
            <Toggle pref="autoSave" /> Auto-save changes
          </label>
          <p>When off, use ⌘S to save. Vireo warns before closing documents with unsaved changes.</p>
        </div>
        <div className="vr-setting vr-setting-row">
          <span>Appearance</span>
          <Choice pref="appearance" options={[["system", "System"], ["light", "Light"], ["dark", "Dark"]]} />
        </div>
        <div className="vr-setting">
          <div className="vr-setting-row">
            <span>Font</span>
            <Choice pref="editorFont" options={[["sans", "Sans"], ["mono", "Mono"]]} />
          </div>
          <p>The typeface of the document text. Code blocks stay monospaced either way.</p>
        </div>
        <div className="vr-setting">
          <label>
            <Toggle pref="showWordCount" /> Show word count
          </label>
          <p>Shows the word and character count in the bottom-right corner of the document.</p>
        </div>
        <div className="vr-setting">
          <div className="vr-setting-row">
            <span>Table of contents</span>
            <Choice pref="tocDefault" options={[["on", "On"], ["off", "Off"], ["dynamic", "Dynamic"]]} />
          </div>
          <p>Whether the table of contents starts open. Dynamic opens it only for longer documents. Applies to documents opened afterwards.</p>
        </div>
        <div className="vr-setting">
          <div className="vr-setting-row">
            <span>Sidebar labels</span>
            <Choice pref="fileLabel" options={[["title", "Document title"], ["filename", "File name"]]} />
          </div>
          <p>Show each file by its first heading or by its file name.</p>
        </div>
      </div>
    </div>
  );
}

export function WordCount() {
  const s = useStore();
  const { words, characters } = s.ui.wordCount;
  return (
    <div className="vr-word-count" aria-live="polite">
      {words} {words === 1 ? "word" : "words"} · {characters} {characters === 1 ? "character" : "characters"}
    </div>
  );
}
