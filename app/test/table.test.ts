import { describe, expect, test } from "bun:test";
import { escapeCell, insertColumn, insertRow, parseTable, removeColumn, removeRow, serialize, setAlign, toGrid } from "../src/editor/table/model";

const src = "| Name | Value |\n|:-----|------:|\n| **a** | 1 |\n|  | x \\| y |";

describe("parseTable", () => {
  test("reads cells, ranges and alignment", () => {
    const t = parseTable(src, 10);
    expect(t.align).toEqual(["left", "right"]);
    expect(t.rows.map((r) => r.map((c) => c.text))).toEqual([
      ["Name", "Value"],
      ["**a**", "1"],
      ["", "x \\| y"],
    ]);
    const a = t.rows[1][0];
    expect(src.slice(a.from - 10, a.to - 10)).toBe("**a**");
  });

  test("an empty cell spans its whole segment", () => {
    const c = parseTable(src).rows[2][0];
    expect(c.empty).toBe(true);
    expect(src.slice(c.from, c.to)).toBe("  ");
  });

  test("tables without outer pipes", () => {
    expect(parseTable("a | b\n--- | ---\n1 | 2").rows.map((r) => r.map((c) => c.text))).toEqual([
      ["a", "b"],
      ["1", "2"],
    ]);
  });
});

describe("escapeCell", () => {
  test("escapes pipes, keeps escapes, flattens newlines", () => {
    expect(escapeCell("a|b")).toBe("a\\|b");
    expect(escapeCell("a\\|b")).toBe("a\\|b");
    expect(escapeCell("one\ntwo")).toBe("one two");
  });
});

describe("structural edits", () => {
  const grid = toGrid(parseTable(src));
  test("serialize normalizes the table", () => {
    expect(serialize(grid)).toBe("| Name | Value |\n| :--- | ---: |\n| **a** | 1 |\n|  | x \\| y |");
  });
  test("rows: never above the header; the header cannot be removed", () => {
    expect(insertRow(grid, 0).rows[1]).toEqual(["", ""]);
    expect(removeRow(grid, 0)).toBe(grid);
    expect(removeRow(grid, 1).rows.length).toBe(2);
  });
  test("columns and alignment", () => {
    const g = insertColumn(grid, 1);
    expect(g.align).toEqual(["left", "", "right"]);
    expect(g.rows[0]).toEqual(["Name", "", "Value"]);
    expect(removeColumn(g, 1)).toEqual(grid);
    expect(setAlign(grid, 0, "center").align).toEqual(["center", "right"]);
  });
  test("the last column cannot be removed", () => {
    const one = toGrid(parseTable("| a |\n|---|"));
    expect(removeColumn(one, 0)).toBe(one);
  });
});
