import { html, raw } from "hono/html";
import type { Child } from "hono/jsx";
import { css } from "./styles";

// Shared chrome for the maintainer dashboards (errors, feedback). Both live
// under the /admin/* prefix specifically so a single Cloudflare Access
// application scoped to /admin* covers both today and any future
// maintainer-only route by construction, without a per-route decision. The
// Worker holds no in-code auth for these routes -- Access enforces at the
// edge before a request ever reaches the Worker -- so do not add ad-hoc auth
// here (an inline API key, a bypassable query param, etc.); that would
// duplicate or conflict with the edge gate. Do not move a route out of
// /admin/* without also updating the Access application's path scope --
// see relay-worker/README.md's runbook.

// Every value rendered into these pages can originate from an
// unauthenticated remote install (POST /crashes/report, POST /feedback are
// both open). That used to make escapeHtml a hand-applied discipline at
// every interpolation point, where a single omission was a stored XSS.
// It no longer is: hono/jsx escapes both child text and attribute values
// automatically, so `{value}` and `href={value}` are safe by construction.
//
// raw() below is the ONLY bypass in the codebase, and it wraps a static
// stylesheet with no interpolation. Do not reach for it anywhere else, and
// do not pass a crash- or feedback-derived value through it.
//
// escapeHtml survives because errors.test.ts tests it directly and because
// it stays correct for any future non-JSX string assembly. It should have no
// callers in markup.
export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// Shared pagination guard for both dashboards' ?page= query param. It is
// arbitrary caller-supplied text on an unauthenticated route, and
// `Number("abc")`/`Number("NaN")`/`Number("Infinity")`/`Number("1e300")`/an
// oversized numeric string each produce a value that reaches D1 as an
// OFFSET and throws `D1_ERROR: datatype mismatch`, surfaced as an unhandled
// Hono 500. Reject anything that isn't a small non-negative safe integer by
// falling back to page 0, and clamp anything absurdly large (but technically
// a safe integer) to MAX_PAGE rather than trusting it straight into the
// query. Originated in dashboards/errors.ts and was duplicated
// verbatim into dashboards/feedback.ts before being extracted
// here -- one copy, so a future fix to this guard can't land in one
// dashboard and not the other.
export const MAX_PAGE = 100_000;

export function parsePage(rawPage: string | undefined): number {
  if (rawPage === undefined) return 0;
  const n = Number(rawPage);
  if (!Number.isSafeInteger(n) || n < 0) return 0;
  return Math.min(n, MAX_PAGE);
}

// Shared "unix seconds -> readable UTC timestamp" formatter for both
// dashboards' list tables. Same extraction reasoning as parsePage above.
//
// The guard is not defensive padding. `toISOString()` throws
// `RangeError: Invalid time value` once `unix * 1000` leaves Date's
// +/-8.64e15ms range, and this runs while BUILDING the page, so one bad row
// does not render as a bad cell -- it takes the whole dashboard down with a
// 500 and keeps it down until someone deletes the row by hand.
//
// The values reach here from `occurred_at` on the unauthenticated
// POST /crashes/report, whose parseOccurredAt (src/crashes/ingest.ts) is
// where this is actually fixed: it now clamps to the same range before
// anything is stored. This guard stays anyway, because that fix only governs
// rows written after it ships, and a row stored before it must not be able to
// break the dashboard the maintainer would use to find it.
export function when(unix: number): string {
  const ms = unix * 1000;
  if (!Number.isFinite(ms) || Math.abs(ms) > 8.64e15) return "invalid date";
  return new Date(ms).toISOString().replace("T", " ").slice(0, 19);
}

export function Layout({ title, children }: { title: string; children?: Child }) {
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{title}</title>
        <style>{raw(css)}</style>
      </head>
      <body>
        <nav class="chrome-nav">
          <a href="/admin/errors">Errors</a>
          <a href="/admin/feedback">Feedback</a>
        </nav>
        <h1>{title}</h1>
        <main>{children}</main>
      </body>
    </html>
  );
}

// hono/jsx renders no doctype of its own, and without one browsers use
// quirks mode, which breaks the stylesheet's box sizing. Every route returns
// through here rather than rendering <Layout> directly.
export function page(title: string, body: Child) {
  return html`<!doctype html>${(<Layout title={title}>{body}</Layout>)}`;
}

// TEMPORARY compatibility shim, removed in Task 5 of this plan.
//
// errors.ts and feedback.ts still build their bodies as HTML strings and
// call layout(title, body). This keeps them working, and the suite green,
// until each is converted. raw() here is safe ONLY because those two callers
// escape every interpolated value themselves; it must not outlive them.
export function layout(title: string, body: string) {
  return page(title, raw(body));
}
