// Checks internal links and anchors in the built site (dist/).
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export const REQUIRED_LINKS = ['/#player', '/server#install', '/download#platforms'];

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    return statSync(full).isDirectory() ? walk(full) : [full];
  });
}

// Page file ("player/index.html") to its URL path ("/player").
function pageUrl(file) {
  const path = '/' + file.replace(/(^|\/)index\.html$/, '$1').replace(/\.html$/, '');
  return path.length > 1 ? path.replace(/\/$/, '') : path;
}

// Resolve a URL path to a page key in `pages`, or null.
function resolvePage(path, pages) {
  const clean = path.replace(/^\/+/, '').replace(/\/$/, '');
  for (const key of [clean ? `${clean}/index.html` : 'index.html', `${clean}.html`]) {
    if (pages.has(key)) return key;
  }
  return null;
}

// Script and style bodies are raw text, not markup, so an id="..." inside one
// names no element.
// Walks the page with indexOf rather than a regex: the build's own output is
// all this reads, and a scan states the intent without HTML-filtering patterns.
function markupOutsideRawText(html) {
  const lower = html.toLowerCase();
  const parts = [];
  let pos = 0;
  while (pos < html.length) {
    const starts = ['<script', '<style'].map((t) => [t, lower.indexOf(t, pos)]).filter(([, i]) => i !== -1);
    if (starts.length === 0) break;
    const [tag, start] = starts.reduce((a, b) => (b[1] < a[1] ? b : a));
    parts.push(html.slice(pos, start));
    const close = lower.indexOf(`</${tag.slice(1)}`, start);
    if (close === -1) return parts;
    const end = lower.indexOf('>', close);
    pos = end === -1 ? html.length : end + 1;
  }
  parts.push(html.slice(pos));
  return parts;
}

function extractIds(html) {
  const parts = markupOutsideRawText(html);
  return new Set(parts.flatMap((part) => [...part.matchAll(/\sid=["']([^"']+)["']/g)].map((m) => m[1])));
}

function extractHrefs(html) {
  return [...html.matchAll(/<a(?=\s)[^>]*?\shref=["']([^"']*)["']/g)].map((m) => m[1]);
}

function isInternal(href) {
  return href !== '' && !/^([a-z][a-z0-9+.-]*:|\/\/)/i.test(href);
}

// pages: Map<"player/index.html", html>; files: Set of every file path in dist.
// Returns one message per broken link.
// functionRoutes: exact paths served by Pages Functions (e.g. "/download/ios").
// They redirect, so a link to one is fine only without a fragment.
export function findBrokenLinks(pages, files, required = REQUIRED_LINKS, functionRoutes = new Set()) {
  const ids = new Map([...pages].map(([key, html]) => [key, extractIds(html)]));
  const broken = [];

  const check = (from, href) => {
    const [beforeHash, fragment] = href.split('#');
    const path = beforeHash.split('?')[0];
    let target;
    if (path === '') {
      target = from;
    } else {
      target = resolvePage(path, pages);
      if (!target) {
        const file = path.replace(/^\/+/, '');
        if (!fragment && (files.has(file) || functionRoutes.has(path.replace(/\/$/, '')))) return;
        broken.push(`${pageUrl(from)}: ${href} (no such page or file)`);
        return;
      }
    }
    if (fragment && !ids.get(target).has(fragment)) {
      broken.push(`${pageUrl(from)}: ${href} (no id="${fragment}" on ${pageUrl(target)})`);
    }
  };

  for (const [file, html] of pages) {
    for (const href of extractHrefs(html)) {
      if (isInternal(href)) check(file, href);
    }
  }
  for (const href of required) check('index.html', href);
  return broken;
}

// /download/<slug> is served by functions/download/[platform].ts, which only
// redirects for the slugs listed in src/lib/release-assets.ts. That file is
// TypeScript, so read its slug arrays from the source rather than import it.
function downloadRoutes(source) {
  const slugs = ['ASSET_PLATFORMS', 'STATIC_PLATFORMS'].flatMap((name) => {
    const m = source.match(new RegExp(`${name}\\s*=\\s*\\[([^\\]]*)\\]`));
    if (!m) throw new Error(`${name} not found in release-assets.ts`);
    return [...m[1].matchAll(/['"]([^'"]+)['"]/g)].map((x) => x[1]);
  });
  return new Set(slugs.map((slug) => `/download/${slug}`));
}

function main() {
  const dist = fileURLToPath(new URL('../dist', import.meta.url));
  const all = walk(dist).map((f) => relative(dist, f).split(sep).join('/'));
  const pages = new Map(
    all.filter((f) => f.endsWith('.html')).map((f) => [f, readFileSync(join(dist, f), 'utf8')]),
  );
  const broken = findBrokenLinks(
    pages,
    new Set(all),
    REQUIRED_LINKS,
    downloadRoutes(
      readFileSync(fileURLToPath(new URL('../src/lib/release-assets.ts', import.meta.url)), 'utf8'),
    ),
  );
  for (const line of broken) console.error(line);
  console.log(`${pages.size} pages checked, ${broken.length} broken links`);
  process.exit(broken.length ? 1 : 0);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
