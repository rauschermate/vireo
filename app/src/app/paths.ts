export const basename = (p: string) => p.slice(p.lastIndexOf("/") + 1);
export const dirname = (p: string) => p.slice(0, p.lastIndexOf("/")) || "/";
export const join = (dir: string, name: string) => (dir.endsWith("/") ? dir + name : `${dir}/${name}`);
export const stem = (name: string) => (name.includes(".") ? name.slice(0, name.lastIndexOf(".")) : name);

const MARKDOWN = /\.(md|markdown|mdown|mkd|mkdn|text)$/i;
export const isMarkdown = (p: string) => MARKDOWN.test(p);

// Resolves a link or image target relative to the folder of a document.
export function resolve(fromDir: string, target: string): string {
  const parts = (target.startsWith("/") ? target : `${fromDir}/${target}`).split("/");
  const out: string[] = [];
  for (const part of parts) {
    if (part === "..") out.pop();
    else if (part !== "." && part !== "") out.push(part);
  }
  return "/" + out.join("/");
}

// A folder path shortened for display: the home folder becomes "~".
export function displayPath(p: string, home?: string): string {
  const h = home ?? (/^\/Users\/[^/]+/.exec(p)?.[0] || "");
  return h && p.startsWith(h) ? "~" + p.slice(h.length) : p;
}

// Rejects names the file system or the user would regret.
export function validateName(name: string): string | null {
  const trimmed = name.trim();
  if (!trimmed) return "Enter a name.";
  if (trimmed.includes("/")) return "A name cannot contain “/”.";
  if (trimmed.startsWith(".")) return "A name cannot start with “.”.";
  return null;
}

// "Untitled.md", then "Untitled 2.md", ... the first name not in `taken`.
export function uniqueName(base: string, ext: string, taken: (name: string) => boolean): string {
  for (let n = 1; ; n++) {
    const name = n === 1 ? `${base}${ext}` : `${base} ${n}${ext}`;
    if (!taken(name)) return name;
  }
}
