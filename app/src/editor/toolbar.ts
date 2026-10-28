import { EditorState, StateCommand, StateEffect, StateField } from "@codemirror/state";
import { EditorView, keymap, showTooltip, Tooltip, TooltipView, ViewUpdate } from "@codemirror/view";
import { ActiveFormats, activeFormats, applyLink, LinkTarget, linkTarget, makeHeading, removeLink, toggleLinePrefix, wrapSelection } from "./format";
import { focusField } from "./reveal";

const svg = (body: string) =>
  `<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;

interface Item {
  label: string;
  html: string;
  active: (f: ActiveFormats) => boolean;
  run: (view: EditorView) => void;
  separatorAfter?: boolean;
}

const command = (cmd: StateCommand) => (view: EditorView) => {
  cmd(view);
};

const allItems: Item[] = [
  { label: "Heading 1", html: "H1", active: (f) => f.heading === 1, run: command(makeHeading(1)) },
  { label: "Heading 2", html: "H2", active: (f) => f.heading === 2, run: command(makeHeading(2)) },
  { label: "Heading 3", html: "H3", active: (f) => f.heading === 3, run: command(makeHeading(3)), separatorAfter: true },
  { label: "Bold", html: "<b>B</b>", active: (f) => f.bold, run: command(wrapSelection("**")) },
  { label: "Italic", html: "<i>I</i>", active: (f) => f.italic, run: command(wrapSelection("*")) },
  { label: "Strikethrough", html: "<s>S</s>", active: (f) => f.strikethrough, run: command(wrapSelection("~~")) },
  {
    label: "Inline Code",
    html: svg('<path d="M5.5 4.5 2 8l3.5 3.5M10.5 4.5 14 8l-3.5 3.5"/>'),
    active: (f) => f.code,
    run: command(wrapSelection("`")),
    separatorAfter: true,
  },
  {
    label: "List",
    html: svg('<path d="M6 4.5h7.5M6 8h7.5M6 11.5h7.5"/><circle cx="2.8" cy="4.5" r=".6" fill="currentColor"/><circle cx="2.8" cy="8" r=".6" fill="currentColor"/><circle cx="2.8" cy="11.5" r=".6" fill="currentColor"/>'),
    active: (f) => f.list,
    run: command(toggleLinePrefix("- ")),
  },
  {
    label: "Quote",
    html: svg('<path d="M3 5h7M3 8h10M3 11h6"/><path d="M1 3.5v9" stroke-width="2"/>'),
    active: (f) => f.quote,
    run: command(toggleLinePrefix("> ")),
  },
  {
    label: "Link",
    html: svg('<path d="M6.8 9.2a2.6 2.6 0 0 0 3.7 0l2.2-2.2a2.6 2.6 0 0 0-3.7-3.7l-.9.9"/><path d="M9.2 6.8a2.6 2.6 0 0 0-3.7 0L3.3 9a2.6 2.6 0 0 0 3.7 3.7l.9-.9"/>'),
    active: (f) => f.link,
    run: (view) => openLinkEditor(view),
  },
];

// CodeMirror anchors a tooltip at its left edge. Vireo centers the toolbar
// over the selection, so report a rect that is centered on the range and as
// wide as the tooltip itself.
function centeredOver(view: EditorView, dom: HTMLElement, from: number, to: number, side: "top" | "bottom") {
  const a = view.coordsAtPos(from, 1);
  const b = view.coordsAtPos(to, -1);
  if (!a || !b) return { left: 0, right: 0, top: -1e5, bottom: -1e5 };
  const content = view.contentDOM.getBoundingClientRect();
  const sameLine = Math.abs(a.top - b.top) < 2;
  const mid = sameLine ? (a.left + b.right) / 2 : (content.left + content.right) / 2;
  const half = dom.offsetWidth / 2;
  const y = side === "top" ? Math.min(a.top, b.top) : Math.max(a.bottom, b.bottom);
  const lineHeight = a.bottom - a.top;
  return side === "top"
    ? { left: mid - half, right: mid + half, top: y, bottom: y + lineHeight }
    : { left: mid - half, right: mid + half, top: y - lineHeight, bottom: y };
}

// A table cell holds inline content only, so its toolbar drops headings,
// lists and quotes, as Vireo's cell toolbar does.
const cellItems = allItems.filter((item) => !["Heading 1", "Heading 2", "Heading 3", "List", "Quote"].includes(item.label));

class ToolbarView implements TooltipView {
  dom = document.createElement("div");
  private buttons: HTMLButtonElement[] = [];

  constructor(
    private view: EditorView,
    private items: Item[],
  ) {
    this.dom.className = "cm-vireo-toolbar";
    this.dom.setAttribute("role", "toolbar");
    for (const item of items) {
      const button = document.createElement("button");
      button.type = "button";
      button.innerHTML = item.html;
      button.title = item.label;
      button.setAttribute("aria-label", item.label);
      // Keep the editor selection: a button must never take focus.
      button.addEventListener("mousedown", (e) => e.preventDefault());
      button.addEventListener("click", () => item.run(this.view));
      this.dom.append(button);
      this.buttons.push(button);
      if (item.separatorAfter && item !== items[items.length - 1]) {
        const sep = document.createElement("span");
        sep.className = "cm-vireo-toolbar-sep";
        this.dom.append(sep);
      }
    }
    this.refresh(view.state);
  }

  update(update: ViewUpdate) {
    if (update.docChanged || update.selectionSet) this.refresh(update.state);
  }

  getCoords() {
    const { from, to } = this.view.state.selection.main;
    return centeredOver(this.view, this.dom, from, to, "top");
  }

  private refresh(state: EditorState) {
    const f = activeFormats(state);
    this.items.forEach((item, i) => this.buttons[i].classList.toggle("is-active", item.active(f)));
  }
}


const setLinkEditor = StateEffect.define<LinkTarget | null>();

const linkEditorField = StateField.define<LinkTarget | null>({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setLinkEditor)) return e.value;
    // Any other edit or caret move closes the editor.
    return tr.docChanged || tr.selection ? null : value;
  },
  provide: (field) => showTooltip.from(field, (target) => (target ? { pos: target.from, above: false, create: linkEditorView(target) } : null)),
});

export function openLinkEditor(view: EditorView) {
  view.dispatch({ effects: setLinkEditor.of(linkTarget(view.state)) });
}

function linkEditorView(target: LinkTarget) {
  return (view: EditorView): TooltipView => {
    const dom = document.createElement("form");
    dom.className = "cm-vireo-link-editor";
    const field = (name: string, value: string, placeholder: string) => {
      const input = document.createElement("input");
      input.name = name;
      input.value = value;
      input.placeholder = placeholder;
      input.spellcheck = false;
      input.autocomplete = "off";
      dom.append(input);
      return input;
    };
    const label = field("label", target.label, "Text");
    const url = field("url", target.url, "https://");
    const actions = document.createElement("div");
    actions.className = "cm-vireo-link-actions";
    dom.append(actions);
    const button = (text: string, type: "submit" | "button", onClick?: () => void) => {
      const b = document.createElement("button");
      b.type = type;
      b.textContent = text;
      if (onClick) b.addEventListener("click", onClick);
      actions.append(b);
      return b;
    };
    const close = (spec: Parameters<EditorView["dispatch"]>[0]) => {
      view.dispatch(spec);
      view.focus();
    };
    if (target.existing) button("Remove", "button", () => close(removeLink(view.state, target))).classList.add("is-remove");
    button("Cancel", "button", () => close({ effects: setLinkEditor.of(null) }));
    button("Save", "submit").classList.add("is-primary");
    dom.addEventListener("submit", (e) => {
      e.preventDefault();
      if (!url.value.trim()) return;
      close(applyLink(view.state, target, label.value || url.value, url.value.trim()));
    });
    dom.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        close({ effects: setLinkEditor.of(null) });
      }
    });
    return {
      dom,
      mount: () => (target.label && target.label !== "link" ? url : label).focus(),
      getCoords: () => centeredOver(view, dom, target.from, target.to, "bottom"),
    };
  };
}

function toolbarField(items: Item[]) {
  // One create function per toolbar, so CodeMirror reuses the tooltip view
  // across selection changes instead of rebuilding it.
  const create = (view: EditorView): TooltipView => new ToolbarView(view, items);
  const toolbarFor = (state: EditorState): Tooltip | null => {
    const sel = state.selection.main;
    if (sel.empty || !state.field(focusField, false) || state.field(linkEditorField)) return null;
    return { pos: sel.from, above: true, create };
  };
  return StateField.define<Tooltip | null>({
    create: toolbarFor,
    update(value, tr) {
      const focusChanged = tr.startState.field(focusField, false) !== tr.state.field(focusField, false);
      const editorChanged = tr.startState.field(linkEditorField) !== tr.state.field(linkEditorField);
      if (!tr.selection && !tr.docChanged && !focusChanged && !editorChanged) return value;
      return toolbarFor(tr.state);
    },
    provide: (field) => showTooltip.from(field),
  });
}

export const formatKeymap = keymap.of([
  { key: "Mod-b", run: wrapSelection("**") },
  { key: "Mod-i", run: wrapSelection("*") },
  { key: "Mod-k", run: (view) => (openLinkEditor(view), true) },
  { key: "Mod-Alt-1", run: makeHeading(1) },
  { key: "Mod-Alt-2", run: makeHeading(2) },
  { key: "Mod-Alt-3", run: makeHeading(3) },
]);

export const formatting = [linkEditorField, toolbarField(allItems), formatKeymap];

export const cellFormatting = [
  linkEditorField,
  toolbarField(cellItems),
  keymap.of([
    { key: "Mod-b", run: wrapSelection("**") },
    { key: "Mod-i", run: wrapSelection("*") },
    { key: "Mod-k", run: (view) => (openLinkEditor(view), true) },
  ]),
];
