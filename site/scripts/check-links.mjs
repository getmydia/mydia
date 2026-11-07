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

function extractIds(html) {
  return new Set([...html.matchAll(/\sid=["']([^"']+)["']/g)].map((m) => m[1]));
}

function extractHrefs(html) {
  return [...html.matchAll(/<a\s[^>]*?href=["']([^"']*)["']/g)].map((m) => m[1]);
}

function isInternal(href) {
  return href !== '' && !/^([a-z][a-z0-9+.-]*:|\/\/)/i.test(href);
}

// pages: Map<"player/index.html", html>; files: Set of every file path in dist.
// Returns one message per broken link.
// dynamicPrefixes: URL prefixes served by Pages Functions ("/download/" for
// functions/download/[platform].ts); a one-segment path under one is not broken.
export function findBrokenLinks(pages, files, required = REQUIRED_LINKS, dynamicPrefixes = []) {
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
        if (dynamicPrefixes.some((p) => /^[^/]+$/.test(path.slice(p.length)) && path.startsWith(p))) return;
        if (!fragment && files.has(file)) return;
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

// functions/<dir>/[param].ts serves /<dir>/<anything>.
function functionPrefixes(root) {
  try {
    return walk(root)
      .map((f) => relative(root, f).split(sep).join('/'))
      .filter((f) => /\/\[[^/]+\]\.[a-z]+$/.test(f))
      .map((f) => '/' + f.slice(0, f.lastIndexOf('/') + 1));
  } catch {
    return [];
  }
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
    functionPrefixes(fileURLToPath(new URL('../functions', import.meta.url))),
  );
  for (const line of broken) console.error(line);
  console.log(`${pages.size} pages checked, ${broken.length} broken links`);
  process.exit(broken.length ? 1 : 0);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
