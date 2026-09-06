// The maintainer dashboards' entire stylesheet, inlined into the page shell
// by layout.tsx. Kept as a string rather than a real .css file on purpose:
// the Worker has no build step (`wrangler deploy` bundles the TypeScript
// directly), and a .css file would need either a bundler or a wrangler Text
// rule plus matching vitest config. Two table pages do not earn that.
//
// Colours are declared once via light-dark(), which needs `color-scheme` on
// the same element to resolve. Do not add a prefers-color-scheme media query
// alongside it; that is the duplication light-dark() exists to remove.
export const css = `
:root {
  color-scheme: light dark;

  --bg:          light-dark(#fcfcfd, #0f1115);
  --surface:     light-dark(#ffffff, #16181d);
  --fg:          light-dark(#18181b, #e4e4e7);
  --muted:       light-dark(#71717a, #9198a5);
  --line:        light-dark(#e6e6e9, #282c34);
  --line-strong: light-dark(#d3d3d8, #3a3f49);
  --accent:      light-dark(#6d28d9, #a78bfa);
  --accent-soft: light-dark(#6d28d914, #a78bfa1f);
  --warn-fg:     light-dark(#8a4b08, #fcd34d);
  --warn-bg:     light-dark(#fdf0d5, #43290b);
  --row-hover:   light-dark(#00000006, #ffffff08);

  --radius:    0.5rem;
  --radius-sm: 0.3rem;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  padding: 2rem 2rem 4rem;
  background: var(--bg);
  color: var(--fg);
  font: 14px/1.55 ui-sans-serif, system-ui, -apple-system, sans-serif;
}

h1 { font-size: 1.35rem; letter-spacing: -0.01em; margin: 0 0 1.25rem; }
h2 { font-size: 1rem; margin: 2rem 0 0.75rem; color: var(--muted); }
a  { color: var(--accent); }

.chrome-nav {
  display: flex;
  gap: 1.25rem;
  padding-bottom: 1rem;
  margin-bottom: 1.5rem;
  border-bottom: 1px solid var(--line);
}
.chrome-nav a { font-weight: 600; text-decoration: none; }
.chrome-nav a:hover { text-decoration: underline; }

/* Filter tabs. The active tab is derived server-side; there is no client JS. */
.tabs { display: flex; gap: 0.35rem; margin: 0 0 1.25rem; padding: 0; }
.tabs a {
  padding: 0.3rem 0.7rem;
  border-radius: var(--radius-sm);
  text-decoration: none;
  color: var(--muted);
}
.tabs a:hover { background: var(--row-hover); color: var(--fg); }
.tabs a[aria-current="page"] { background: var(--accent-soft); color: var(--accent); font-weight: 600; }

.table-wrap { overflow-x: auto; border: 1px solid var(--line); border-radius: var(--radius); background: var(--surface); }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: 0.6rem 0.8rem; border-bottom: 1px solid var(--line); vertical-align: top; }
th { font-weight: 600; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); white-space: nowrap; }
tbody tr:last-child td { border-bottom: 0; }
tbody tr:hover td { background: var(--row-hover); }

.muted { color: var(--muted); }
.num   { font-variant-numeric: tabular-nums; white-space: nowrap; }
.wrap  { white-space: pre-wrap; max-width: 32rem; }

pre {
  overflow-x: auto;
  background: var(--bg);
  border: 1px solid var(--line);
  padding: 0.75rem;
  border-radius: var(--radius-sm);
  font-size: 0.8rem;
}

.badge {
  display: inline-block;
  margin-left: 0.4rem;
  padding: 0.05rem 0.4rem;
  border-radius: var(--radius-sm);
  font-size: 0.72rem;
  font-weight: 600;
  background: var(--warn-bg);
  color: var(--warn-fg);
  cursor: help;
}

details { border: 1px solid var(--line); border-radius: var(--radius); padding: 0.6rem 0.85rem; margin-bottom: 0.5rem; background: var(--surface); }
details[open] { padding-bottom: 0.85rem; }
summary { cursor: pointer; font-variant-numeric: tabular-nums; }
summary:hover { color: var(--accent); }

form { display: inline; }
button {
  font: inherit;
  font-size: 0.8rem;
  padding: 0.2rem 0.55rem;
  border: 1px solid var(--line-strong);
  border-radius: var(--radius-sm);
  background: var(--surface);
  color: var(--fg);
  cursor: pointer;
}
button:hover { border-color: var(--accent); color: var(--accent); }

input[type="text"] {
  font: inherit;
  font-size: 0.8rem;
  padding: 0.2rem 0.4rem;
  border: 1px solid var(--line-strong);
  border-radius: var(--radius-sm);
  background: var(--bg);
  color: var(--fg);
}
input[type="text"]:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }

.pager { margin-top: 1.25rem; }
`;
