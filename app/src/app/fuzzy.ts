// Subsequence matching for quick open. Matches in the file name beat matches
// in the folder path; consecutive characters and word starts score higher.

export interface Match {
  score: number;
  // Indices into the matched string, for highlighting.
  indices: number[];
}

const BOUNDARY = /[\s/\\_\-.]/;

export function fuzzyMatch(query: string, target: string): Match | null {
  const q = query.toLowerCase().replace(/\s+/g, "");
  if (!q) return { score: 0, indices: [] };
  const t = target.toLowerCase();
  const indices: number[] = [];
  let score = 0;
  let ti = 0;
  let streak = 0;
  for (let qi = 0; qi < q.length; qi++) {
    const found = t.indexOf(q[qi], ti);
    if (found < 0) return null;
    const atBoundary = found === 0 || BOUNDARY.test(target[found - 1]) || (target[found] !== t[found] && target[found - 1] === t[found - 1]);
    streak = found === ti && qi > 0 ? streak + 1 : 0;
    score += 1 + streak * 3 + (atBoundary ? 4 : 0) - Math.min(found - ti, 5) * 0.2;
    indices.push(found);
    ti = found + 1;
  }
  return { score: score - target.length * 0.01, indices };
}

export interface Candidate {
  path: string;
  name: string;
  folder: string;
}

export interface Ranked extends Candidate {
  score: number;
  nameIndices: number[];
}

export function rank(query: string, candidates: Candidate[], limit = 50): Ranked[] {
  const out: Ranked[] = [];
  for (const c of candidates) {
    const inName = fuzzyMatch(query, c.name);
    if (inName) {
      out.push({ ...c, score: inName.score + 10, nameIndices: inName.indices });
      continue;
    }
    const inPath = fuzzyMatch(query, `${c.folder}/${c.name}`);
    if (inPath) out.push({ ...c, score: inPath.score, nameIndices: [] });
  }
  return out.sort((a, b) => b.score - a.score || a.name.localeCompare(b.name)).slice(0, limit);
}
