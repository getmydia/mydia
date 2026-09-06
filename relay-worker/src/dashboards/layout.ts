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

// Every value rendered into one of these pages can originate from an
// unauthenticated remote install (POST /crashes/report, POST /feedback are
// both open). escapeHtml is the one and only sanctioned way to interpolate
// dynamic text into a template string here -- never interpolate a
// crash/feedback-derived value without it, including values that "look safe"
// like a hex fingerprint or an integer count.
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

export function parsePage(raw: string | undefined): number {
  if (raw === undefined) return 0;
  const n = Number(raw);
  if (!Number.isSafeInteger(n) || n < 0) return 0;
  return Math.min(n, MAX_PAGE);
}

// Shared "unix seconds -> readable UTC timestamp" formatter for both
// dashboards' list tables. Same extraction reasoning as parsePage above.
export function when(unix: number): string {
  return new Date(unix * 1000).toISOString().replace("T", " ").slice(0, 19);
}

export function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.5 ui-sans-serif, system-ui, sans-serif; margin: 0; padding: 2rem; }
  h1 { font-size: 1.25rem; }
  nav a { margin-right: 1rem; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: .5rem .75rem; border-bottom: 1px solid #8883; vertical-align: top; }
  th { font-weight: 600; }
  pre { overflow-x: auto; background: #8881; padding: .75rem; border-radius: .375rem; }
  .muted { opacity: .65; }
  .wrap { white-space: pre-wrap; }
  .floor { white-space: nowrap; }
  .floor .badge {
    display: inline-block; margin-left: .35rem; padding: .05rem .4rem;
    border-radius: .25rem; font-size: .75rem; background: #f59e0b3d; color: inherit;
  }
  form { display: inline; }
  button { font: inherit; padding: .25rem .6rem; cursor: pointer; }
</style>
</head>
<body>
<nav><a href="/admin/errors">Errors</a><a href="/admin/feedback">Feedback</a></nav>
<h1>${escapeHtml(title)}</h1>
${body}
</body>
</html>`;
}
