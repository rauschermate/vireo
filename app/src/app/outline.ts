// Headings for the outline sidebar. A line scan instead of the syntax tree:
// the tree only covers the part of the file near the viewport, and the
// outline needs the whole file. Fenced code is skipped.

export interface Heading {
  level: number;
  text: string;
  from: number;
}

const ATX = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/;
const FENCE = /^ {0,3}(`{3,}|~{3,})/;
const SETEXT = /^ {0,3}(=+|-+)[ \t]*$/;

export function plainHeading(text: string): string {
  return text
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/(\*\*|__|~~|`)(.+?)\1/g, "$2")
    .replace(/(\*|_)(.+?)\1/g, "$2")
    .replace(/\\([\\`*_{}[\]()#+\-.!|])/g, "$1")
    .trim();
}

export function outline(doc: string): Heading[] {
  const out: Heading[] = [];
  let fence: string | null = null;
  let pos = 0;
  let prev: { text: string; from: number; paragraph: boolean } | null = null;
  for (const line of doc.split("\n")) {
    const from = pos;
    pos += line.length + 1;
    const f = FENCE.exec(line);
    if (fence) {
      if (f && f[1][0] === fence[0] && f[1].length >= fence.length && line.trim() === f[1]) fence = null;
      prev = null;
      continue;
    }
    if (f) {
      fence = f[1];
      prev = null;
      continue;
    }
    const atx = ATX.exec(line);
    if (atx) {
      out.push({ level: atx[1].length, text: plainHeading(atx[2] ?? ""), from });
      prev = null;
      continue;
    }
    const setext = SETEXT.exec(line);
    if (setext && prev?.paragraph) {
      out.push({ level: setext[1][0] === "=" ? 1 : 2, text: plainHeading(prev.text), from: prev.from });
      prev = null;
      continue;
    }
    const trimmed = line.trim();
    // Only a plain paragraph line can become a setext heading.
    const paragraph = trimmed !== "" && !/^([-*+]|\d+[.)])\s|^>|^\||^ {4}/.test(line);
    prev = trimmed ? { text: trimmed, from, paragraph } : null;
  }
  return out;
}

// The heading whose section holds `pos`.
export function currentHeading(headings: Heading[], pos: number): number {
  let lo = 0;
  let hi = headings.length - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (headings[mid].from <= pos) {
      found = mid;
      lo = mid + 1;
    } else hi = mid - 1;
  }
  return found;
}

// GitHub-style anchor slugs, for #anchor links.
export function slug(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s_-]/gu, "")
    .trim()
    .replace(/\s/g, "-");
}
