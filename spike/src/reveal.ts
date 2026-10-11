import { EditorState, StateEffect, StateField } from "@codemirror/state";
import { EditorView } from "@codemirror/view";

const focusEffect = StateEffect.define<boolean>();

// Block decorations live in a StateField, which cannot see `view.hasFocus`.
// Mirror focus into state so the inline plugin and the block field agree.
export const focusField = StateField.define<boolean>({
  create: () => false,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(focusEffect)) value = e.value;
    return value;
  },
});

export const focusTracking = [
  focusField,
  EditorView.focusChangeEffect.of((_state, focusing) => focusEffect.of(focusing)),
];

export function revealed(state: EditorState, from: number, to: number): boolean {
  if (!state.field(focusField, false)) return false;
  for (const r of state.selection.ranges) if (r.from <= to && r.to >= from) return true;
  return false;
}

export function lineRevealed(state: EditorState, pos: number): boolean {
  const line = state.doc.lineAt(pos);
  return revealed(state, line.from, line.to);
}
