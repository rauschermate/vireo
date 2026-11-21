import { createContext, ReactNode, useContext, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import type { Store } from "./store";

export const StoreContext = createContext<Store | null>(null);

// Re-renders the component on every store change. The chrome is small, and
// the store never emits on plain keystrokes.
export function useStore(): Store {
  const store = useContext(StoreContext)!;
  useSyncExternalStore(store.subscribe, store.getVersion);
  return store;
}

export type MenuItem = { label: string; run: () => void; enabled?: boolean; checked?: boolean; danger?: boolean } | "-";

type MenuState = { x: number; y: number; items: MenuItem[] } | null;
let menuState: MenuState = null;
const menuListeners = new Set<() => void>();
const setMenu = (m: MenuState) => {
  menuState = m;
  menuListeners.forEach((l) => l());
};

export function showContextMenu(event: { clientX: number; clientY: number; preventDefault(): void }, items: MenuItem[]) {
  event.preventDefault();
  setMenu({ x: event.clientX, y: event.clientY, items });
}

export function ContextMenuHost() {
  const menu = useSyncExternalStore(
    (l) => (menuListeners.add(l), () => void menuListeners.delete(l)),
    () => menuState,
  );
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ x: 0, y: 0 });
  const [active, setActive] = useState(-1);

  useLayoutEffect(() => {
    if (!menu || !ref.current) return;
    const r = ref.current.getBoundingClientRect();
    setPos({ x: Math.min(menu.x, innerWidth - r.width - 6), y: menu.y + r.height > innerHeight - 6 ? Math.max(6, menu.y - r.height) : menu.y });
    setActive(-1);
    ref.current.focus();
  }, [menu]);

  useEffect(() => {
    if (!menu) return;
    const close = (e: Event) => {
      if (e.type === "mousedown" && ref.current?.contains(e.target as Node)) return;
      setMenu(null);
    };
    addEventListener("mousedown", close, true);
    addEventListener("blur", close);
    addEventListener("resize", close);
    return () => {
      removeEventListener("mousedown", close, true);
      removeEventListener("blur", close);
      removeEventListener("resize", close);
    };
  }, [menu]);

  if (!menu) return null;
  const actionable = menu.items.map((item, i) => (item !== "-" && item.enabled !== false ? i : -1)).filter((i) => i >= 0);
  const pick = (item: MenuItem) => {
    if (item === "-" || item.enabled === false) return;
    setMenu(null);
    item.run();
  };
  return (
    <div
      ref={ref}
      className="vr-menu"
      role="menu"
      tabIndex={-1}
      style={{ left: pos.x, top: pos.y }}
      onKeyDown={(e) => {
        if (e.key === "Escape") setMenu(null);
        else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
          e.preventDefault();
          const at = actionable.indexOf(active);
          const next = e.key === "ArrowDown" ? actionable[(at + 1) % actionable.length] : actionable[(at - 1 + actionable.length) % actionable.length];
          setActive(next);
        } else if (e.key === "Enter" && active >= 0) pick(menu.items[active]);
      }}
    >
      {menu.items.map((item, i) =>
        item === "-" ? (
          <div key={i} className="vr-menu-sep" />
        ) : (
          <button
            key={i}
            type="button"
            role="menuitem"
            disabled={item.enabled === false}
            className={(i === active ? "is-active " : "") + (item.danger ? "is-danger" : "")}
            onMouseEnter={() => setActive(i)}
            onClick={() => pick(item)}
          >
            <span className="vr-menu-check">{item.checked ? "✓" : ""}</span>
            {item.label}
          </button>
        ),
      )}
    </div>
  );
}

// A text field that commits on Enter or blur and cancels on Escape.
export function InlineEdit({ value, onCommit, onCancel, className, selectStem }: { value: string; onCommit: (v: string) => void; onCancel: () => void; className?: string; selectStem?: boolean }) {
  const ref = useRef<HTMLInputElement>(null);
  const done = useRef(false);
  useEffect(() => {
    const input = ref.current!;
    input.focus();
    const dot = value.lastIndexOf(".");
    if (selectStem && dot > 0) input.setSelectionRange(0, dot);
    else input.select();
  }, []);
  const finish = (commit: boolean) => {
    if (done.current) return;
    done.current = true;
    if (commit) onCommit(ref.current!.value);
    else onCancel();
  };
  return (
    <input
      ref={ref}
      className={"vr-inline-edit " + (className ?? "")}
      defaultValue={value}
      spellCheck={false}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") finish(true);
        else if (e.key === "Escape") finish(false);
      }}
      onBlur={() => finish(true)}
      onClick={(e) => e.stopPropagation()}
      onDoubleClick={(e) => e.stopPropagation()}
    />
  );
}

export function Icon({ name }: { name: "sidebar" | "chevron" | "chevronDown" | "plus" | "close" | "warning" | "doc" | "folder" | "pin" }): ReactNode {
  const paths: Record<string, ReactNode> = {
    sidebar: (
      <>
        <rect x="2" y="3" width="12" height="10" rx="2" />
        <path d="M6 3v10" />
      </>
    ),
    chevron: <path d="M6 4l4 4-4 4" />,
    chevronDown: <path d="M4 6l4 4 4-4" />,
    plus: <path d="M8 3.5v9M3.5 8h9" />,
    close: <path d="M4.5 4.5l7 7M11.5 4.5l-7 7" />,
    warning: (
      <>
        <path d="M8 2.5l6 10.5H2z" />
        <path d="M8 6.5v3M8 11.2v.1" />
      </>
    ),
    doc: <path d="M4 2.5h5l3 3v8H4zM9 2.5v3h3" />,
    folder: <path d="M2 4.5h4l1.5 1.5H14v6.5H2z" />,
    pin: <path d="M6 2.5h4l-.5 4 2 2H4.5l2-2zM8 8.5V14" />,
  };
  return (
    <svg className={`vr-icon vr-icon-${name}`} viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {paths[name]}
    </svg>
  );
}
