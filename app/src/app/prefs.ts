// Vireo's preferences, with the same defaults. Zoom and focus mode are
// session-only, as in Vireo.

export interface Prefs {
  autoSave: boolean;
  appearance: "system" | "light" | "dark";
  tocDefault: "on" | "off" | "dynamic";
  editorFont: "sans" | "mono";
  showWordCount: boolean;
  sidebarVisible: boolean;
  sidebarWidth: number;
  fileLabel: "title" | "filename";
  showSearch: boolean;
  showRecents: boolean;
  recentFiles: string[];
  recentWorkspaces: string[];
  lastWorkspace: string | null;
  pinned: Record<string, string[]>;
  hasOpenedWelcome: boolean;
}

export const defaultPrefs: Prefs = {
  autoSave: true,
  appearance: "system",
  tocDefault: "dynamic",
  editorFont: "sans",
  showWordCount: false,
  sidebarVisible: true,
  sidebarWidth: 240,
  fileLabel: "title",
  showSearch: true,
  showRecents: true,
  recentFiles: [],
  recentWorkspaces: [],
  lastWorkspace: null,
  pinned: {},
  hasOpenedWelcome: false,
};

export const RECENT_LIMIT = 10;
export const SIDEBAR_MIN = 220;
export const SIDEBAR_MAX = 420;

export function parsePrefs(json: string): Prefs {
  let raw: Record<string, unknown> = {};
  try {
    raw = JSON.parse(json) ?? {};
  } catch {}
  const prefs = { ...defaultPrefs };
  for (const key of Object.keys(defaultPrefs) as (keyof Prefs)[]) {
    const value = raw[key];
    if (value !== undefined && typeof value === typeof defaultPrefs[key]) (prefs as any)[key] = value;
    else if (key === "lastWorkspace" && typeof value === "string") prefs.lastWorkspace = value;
  }
  // The memory backend seeds a workspace under this older key.
  if (typeof raw.workspace === "string" && !prefs.lastWorkspace) prefs.lastWorkspace = raw.workspace;
  return prefs;
}

// Most recent first, without duplicates, capped.
export function pushRecent(list: string[], item: string): string[] {
  return [item, ...list.filter((x) => x !== item)].slice(0, RECENT_LIMIT);
}

// "Dynamic" opens the outline only for longer documents.
export function tocOpenByDefault(pref: Prefs["tocDefault"], text: string): boolean {
  if (pref !== "dynamic") return pref === "on";
  if (text.length >= 4000) return true;
  let lines = 0;
  for (let i = 0; i < text.length && lines < 100; i++) if (text.charCodeAt(i) === 10) lines++;
  return lines >= 100;
}
