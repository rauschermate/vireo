import { describe, expect, test } from "bun:test";
import { rank } from "../src/app/fuzzy";
import { currentHeading, outline, slug } from "../src/app/outline";
import { resolve, uniqueName, validateName } from "../src/app/paths";

describe("outline", () => {
  test("ATX and setext headings, with inline markup removed", () => {
    const doc = "# One **bold**\n\ntext\n\nTwo\n===\n\n## Three [link](x) ##\n\nPara\n---\n";
    expect(outline(doc).map((h) => [h.level, h.text])).toEqual([
      [1, "One bold"],
      [1, "Two"],
      [2, "Three link"],
      [2, "Para"],
    ]);
  });

  test("skips fenced code and does not treat list items as setext", () => {
    const doc = "```\n# not a heading\n```\n- item\n---\n~~~~\n## nope\n~~~\n## still code\n~~~~\n# Real";
    expect(outline(doc).map((h) => h.text)).toEqual(["Real"]);
  });

  test("offsets point at the heading line", () => {
    const doc = "intro\n\n## Here\n";
    const [h] = outline(doc);
    expect(doc.slice(h.from, h.from + 7)).toBe("## Here");
  });

  test("currentHeading finds the section", () => {
    const hs = outline("# A\n\ntext\n\n## B\n\nmore");
    expect(currentHeading(hs, 0)).toBe(0);
    expect(currentHeading(hs, 8)).toBe(0);
    expect(currentHeading(hs, 13)).toBe(1);
  });

  test("slugs match GitHub", () => {
    expect(slug("Lists, since everyone keeps one")).toBe("lists-since-everyone-keeps-one");
    expect(slug("Code: kept honest!")).toBe("code-kept-honest");
  });
});

describe("fuzzy rank", () => {
  const files = ["/n/Welcome.md", "/n/Projects/Roadmap.md", "/n/Journal/2026-10-27.md", "/n/Projects/Vireo/Ideas.md"].map((path) => ({
    path,
    name: path.slice(path.lastIndexOf("/") + 1),
    folder: path.slice(0, path.lastIndexOf("/")),
  }));
  test("file name matches rank first", () => {
    expect(rank("road", files)[0].name).toBe("Roadmap.md");
    expect(rank("wel", files)[0].name).toBe("Welcome.md");
  });
  test("folder matches still appear", () => {
    expect(rank("vireo", files).map((r) => r.name)).toEqual(["Ideas.md"]);
  });
  test("no match, no result", () => {
    expect(rank("zzz", files)).toEqual([]);
  });
});

describe("paths", () => {
  test("resolve relative targets", () => {
    expect(resolve("/a/b", "../c/d.md")).toBe("/a/c/d.md");
    expect(resolve("/a/b", "./img.png")).toBe("/a/b/img.png");
    expect(resolve("/a/b", "/abs.md")).toBe("/abs.md");
  });
  test("unique names", () => {
    const taken = new Set(["Untitled.md", "Untitled 2.md"]);
    expect(uniqueName("Untitled", ".md", (n) => taken.has(n))).toBe("Untitled 3.md");
  });
  test("name validation", () => {
    expect(validateName("a/b")).not.toBeNull();
    expect(validateName(" ")).not.toBeNull();
    expect(validateName("ok.md")).toBeNull();
  });
});
