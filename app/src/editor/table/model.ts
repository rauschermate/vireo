// GFM table source <-> model. A cell edit replaces only that cell's source
// range, so the rest of the file stays byte-identical. Row and column actions
// rewrite the whole table, like Vireo's EditableMarkdownTable.

export type Align = "" | "left" | "center" | "right";

export interface Cell {
  text: string;
  // The trimmed content range. For an empty cell this is the whole segment
  // between the pipes, so an edit can pad the new text with spaces.
  from: number;
  to: number;
  empty: boolean;
}

export interface Table {
  from: number;
  to: number;
  align: Align[];
  // rows[0] is the header. Rows may have fewer cells than columns.
  rows: Cell[][];
}

function segments(line: string): [number, number][] {
  const pipes: number[] = [];
  for (let i = 0; i < line.length; i++) {
    if (line[i] === "\\") i++;
    else if (line[i] === "|") pipes.push(i);
  }
  const bounds = [-1, ...pipes, line.length];
  let segs: [number, number][] = [];
  for (let k = 0; k + 1 < bounds.length; k++) segs.push([bounds[k] + 1, bounds[k + 1]]);
  const first = line.search(/\S/);
  const last = line.length - 1 - (line.length - line.trimEnd().length);
  if (pipes.length && pipes[0] === first) segs = segs.slice(1);
  if (pipes.length && pipes[pipes.length - 1] === last && last > first) segs = segs.slice(0, -1);
  return segs;
}

function cells(line: string, lineFrom: number): Cell[] {
  return segments(line).map(([a, b]) => {
    const raw = line.slice(a, b);
    const lead = raw.length - raw.trimStart().length;
    const text = raw.trim();
    if (!text) return { text: "", from: lineFrom + a, to: lineFrom + b, empty: true };
    return { text, from: lineFrom + a + lead, to: lineFrom + a + lead + text.length, empty: false };
  });
}

function alignOf(spec: string): Align {
  const s = spec.trim();
  const left = s.startsWith(":");
  const right = s.endsWith(":");
  return left && right ? "center" : right ? "right" : left ? "left" : "";
}

export function parseTable(source: string, from = 0): Table {
  const lines = source.split("\n");
  const rows: Cell[][] = [];
  let align: Align[] = [];
  let pos = from;
  lines.forEach((line, i) => {
    if (i === 1) align = segments(line).map(([a, b]) => alignOf(line.slice(a, b)));
    else rows.push(cells(line, pos));
    pos += line.length + 1;
  });
  return { from, to: from + source.length, align, rows };
}

// Newlines cannot live in a cell, and an unescaped pipe would split it.
export function escapeCell(text: string): string {
  let out = "";
  const flat = text.replace(/\r?\n|\r/g, " ");
  for (let i = 0; i < flat.length; i++) {
    const c = flat[i];
    if (c === "\\" && i + 1 < flat.length) {
      out += c + flat[++i];
      continue;
    }
    out += c === "|" ? "\\|" : c;
  }
  return out.trim();
}

export interface Grid {
  align: Align[];
  rows: string[][];
}

export function toGrid(table: Table): Grid {
  const columns = table.align.length;
  return {
    align: [...table.align],
    rows: table.rows.map((row) => Array.from({ length: columns }, (_, c) => row[c]?.text ?? "")),
  };
}

const separator = (a: Align) => (a === "left" ? ":---" : a === "center" ? ":---:" : a === "right" ? "---:" : "---");

export function serialize(grid: Grid): string {
  const line = (cells: string[]) => "| " + cells.join(" | ") + " |";
  const [header, ...body] = grid.rows;
  return [line(header), "| " + grid.align.map(separator).join(" | ") + " |", ...body.map(line)].join("\n");
}

export function insertRow(grid: Grid, index: number): Grid {
  const at = Math.min(Math.max(1, index), grid.rows.length);
  const rows = [...grid.rows];
  rows.splice(at, 0, grid.align.map(() => ""));
  return { ...grid, rows };
}

export function removeRow(grid: Grid, index: number): Grid {
  if (index < 1 || index >= grid.rows.length) return grid;
  return { ...grid, rows: grid.rows.filter((_, i) => i !== index) };
}

export function insertColumn(grid: Grid, index: number): Grid {
  const at = Math.min(Math.max(0, index), grid.align.length);
  const align = [...grid.align];
  align.splice(at, 0, "");
  return { align, rows: grid.rows.map((r) => [...r.slice(0, at), "", ...r.slice(at)]) };
}

export function removeColumn(grid: Grid, index: number): Grid {
  if (grid.align.length < 2 || index < 0 || index >= grid.align.length) return grid;
  return { align: grid.align.filter((_, i) => i !== index), rows: grid.rows.map((r) => r.filter((_, i) => i !== index)) };
}

export function setAlign(grid: Grid, column: number, align: Align): Grid {
  return { ...grid, align: grid.align.map((a, i) => (i === column ? align : a)) };
}
