import { Facet } from "@codemirror/state";

// What the editor needs from the app around it, per document. The bench page
// and tests use the defaults.

// Turns an image source from the markdown into a URL the web view can load.
export const resolveResource = Facet.define<(src: string) => string, (src: string) => string>({
  combine: (values) => values[0] ?? ((src) => src),
});

// Opens a link target: a URL, a local file, or a #anchor.
export const openLink = Facet.define<(target: string) => void, (target: string) => void>({
  combine: (values) => values[0] ?? ((target) => void window.open(target, "_blank")),
});
