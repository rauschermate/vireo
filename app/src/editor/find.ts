import {
  closeSearchPanel,
  findNext,
  findPrevious,
  getSearchQuery,
  replaceAll,
  replaceNext,
  search,
  searchKeymap,
  SearchQuery,
  setSearchQuery,
} from "@codemirror/search";
import { EditorState } from "@codemirror/state";
import { EditorView, keymap, Panel, ViewUpdate } from "@codemirror/view";

// Counting stops here, so a common term in a huge file stays cheap.
const COUNT_LIMIT = 1000;

function count(state: EditorState, query: SearchQuery): { total: number; current: number } {
  if (!query.valid || !query.search) return { total: 0, current: 0 };
  const sel = state.selection.main;
  let total = 0;
  let current = 0;
  const cursor = query.getCursor(state);
  for (let next = cursor.next(); !next.done && total < COUNT_LIMIT; next = cursor.next()) {
    total++;
    if (next.value.from === sel.from && next.value.to === sel.to) current = total;
  }
  return { total, current };
}

function findPanel(view: EditorView): Panel {
  const dom = document.createElement("div");
  dom.className = "cm-vireo-find";
  const row = (cls: string) => {
    const r = document.createElement("div");
    r.className = cls;
    dom.append(r);
    return r;
  };
  const findRow = row("cm-vireo-find-row");
  const replaceRow = row("cm-vireo-find-row cm-vireo-replace-row");
  replaceRow.hidden = true;

  const input = (placeholder: string, name: string) => {
    const el = document.createElement("input");
    el.type = "search";
    el.placeholder = placeholder;
    el.name = name;
    el.spellcheck = false;
    el.autocomplete = "off";
    el.setAttribute("main-field", name === "search" ? "true" : "false");
    return el;
  };
  const button = (label: string, title: string, onClick: () => void) => {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = label;
    b.title = title;
    b.setAttribute("aria-label", title);
    b.addEventListener("click", onClick);
    return b;
  };

  const query0 = getSearchQuery(view.state);
  const searchField = input("Find", "search");
  searchField.value = query0.search;
  const replaceField = input("Replace", "replace");
  replaceField.value = query0.replace;
  const counter = document.createElement("span");
  counter.className = "cm-vireo-find-count";
  const caseToggle = button("Aa", "Match Case", () => {
    caseToggle.classList.toggle("is-on");
    commit(true);
  });
  caseToggle.classList.toggle("is-on", query0.caseSensitive);
  const replaceToggle = button("Replace", "Show Replace", () => {
    replaceRow.hidden = !replaceRow.hidden;
    replaceToggle.classList.toggle("is-on", !replaceRow.hidden);
  });

  findRow.append(
    searchField,
    counter,
    button("‹", "Previous Match", () => findPrevious(view)),
    button("›", "Next Match", () => findNext(view)),
    caseToggle,
    replaceToggle,
    button("Done", "Done", () => closeSearchPanel(view)),
  );
  replaceRow.append(
    replaceField,
    button("Replace", "Replace", () => replaceNext(view)),
    button("All", "Replace All", () => replaceAll(view)),
  );

  const origin = view.state.selection.main.from;
  // Live search: each keystroke jumps to the first match at or after the
  // place the search started, like the native find bar.
  function commit(jump: boolean) {
    const query = new SearchQuery({ search: searchField.value, replace: replaceField.value, caseSensitive: caseToggle.classList.contains("is-on") });
    view.dispatch({ effects: setSearchQuery.of(query) });
    if (jump && query.valid && query.search) {
      let match = query.getCursor(view.state, origin).next();
      if (match.done) match = query.getCursor(view.state).next();
      if (!match.done) view.dispatch({ selection: { anchor: match.value.from, head: match.value.to }, scrollIntoView: true });
    }
    refresh(view.state);
  }
  // Counting walks every match, so it waits until typing pauses. The jump to
  // the first match stays immediate.
  let pending = 0;
  function refresh(state: EditorState) {
    clearTimeout(pending);
    pending = window.setTimeout(() => recount(view.state), 100);
    if (!getSearchQuery(state).search) recount(state);
  }
  function recount(state: EditorState) {
    const query = getSearchQuery(state);
    const { total, current } = count(state, query);
    counter.textContent = !query.search ? "" : total === 0 ? "No matches" : `${current || "–"} of ${total >= COUNT_LIMIT ? `${COUNT_LIMIT}+` : total}`;
    dom.classList.toggle("is-empty", !!query.search && total === 0);
  }

  searchField.addEventListener("input", () => commit(true));
  replaceField.addEventListener("input", () => commit(false));
  for (const field of [searchField, replaceField]) {
    field.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        if (field === replaceField) replaceNext(view);
        else (e.shiftKey ? findPrevious : findNext)(view);
      } else if (e.key === "Escape") {
        e.preventDefault();
        closeSearchPanel(view);
      }
    });
  }

  return {
    dom,
    top: true,
    mount() {
      searchField.focus();
      searchField.select();
      recount(view.state);
    },
    destroy() {
      clearTimeout(pending);
    },
    update(update: ViewUpdate) {
      if (update.docChanged || update.selectionSet || update.transactions.some((tr) => tr.effects.some((e) => e.is(setSearchQuery)))) {
        refresh(update.state);
      }
    },
  };
}

export const find = [search({ top: true, createPanel: findPanel }), keymap.of(searchKeymap)];
