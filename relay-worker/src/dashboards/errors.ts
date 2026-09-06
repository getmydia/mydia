import type { Hono } from "hono";
import type { Env } from "../env";
import { listErrors, getError, setErrorStatus } from "../crashes/queries";
import { layout, escapeHtml, parsePage, when } from "./layout";

const PAGE_SIZE = 50;

// fingerprintOf (src/crashes/ingest.ts) always produces exactly 32 lowercase
// hex characters (the first 32 hex chars of a SHA-256 digest). Anything else
// in the :fingerprint path segment cannot be a real error group.
const FINGERPRINT_SHAPE = /^[0-9a-f]{32}$/;

function isValidFingerprintShape(value: string): boolean {
  return FINGERPRINT_SHAPE.test(value);
}

function formatInteger(n: number): string {
  return Math.trunc(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

// The single place a raw occurrence_count is turned into markup. When
// errors.count_is_floor is set (ingest.ts sets it the moment any of this
// fingerprint's buckets ever saturates, and never clears it -- see
// 0002_crash_reports.sql), occurrence_count is a FLOOR, not an exact total:
// rendering it as a bare number would present a throttled undercount as if
// it were precise, worst exactly during the crash storm an operator is
// trying to understand. "&ge;" plus a visible "throttled" badge is the
// distinguishing signal; nothing here is attacker-controlled (occurrence_count
// is an integer column, the label text is a fixed string) but it is still
// routed through escapeHtml for the same reason every other interpolated
// value in this file is: never special case a value here just because it
// looks safe today.
function renderCount(count: number, isFloor: boolean): string {
  const value = escapeHtml(formatInteger(count));
  if (!isFloor) return value;
  return `<span class="floor">&ge;&nbsp;${value}<span class="badge" title="The ingest throttle saturated at least one hourly bucket for this error at some point. Crashes beyond the per-hour cap were accepted but not counted, so this total is a permanent floor, not an exact count.">throttled</span></span>`;
}

export function registerErrorDashboard(app: Hono<{ Bindings: Env }>): void {
  app.get("/admin/errors", async (c) => {
    const status = c.req.query("status") ?? undefined;
    const page = parsePage(c.req.query("page"));
    const rows = await listErrors(c.env, {
      status,
      limit: PAGE_SIZE,
      offset: page * PAGE_SIZE,
    });

    const body = `
<p class="muted">
  <a href="/admin/errors">all</a>
  <a href="/admin/errors?status=unresolved">unresolved</a>
  <a href="/admin/errors?status=resolved">resolved</a>
</p>
<table>
  <thead><tr><th>Kind</th><th>Message</th><th>Source</th><th>Count</th><th>Last seen</th><th>Status</th></tr></thead>
  <tbody>
    ${
      // escapeHtml(r.fingerprint) below (in the <a href>) is defense in
      // depth, NOT what makes that href safe -- escapeHtml only neutralises
      // HTML metacharacters, not URL-structural ones (a slash, "?", "#", a
      // raw CRLF). What actually makes it safe is that the surrounding path
      // is the fixed literal "/admin/errors/" and fingerprintOf's output is
      // constrained to 32 lowercase hex characters. If fingerprint
      // generation ever allows arbitrary bytes, this href needs its own
      // encodeURIComponent, not just escapeHtml.
      rows
        .map(
          (r) => `<tr>
      <td><a href="/admin/errors/${escapeHtml(r.fingerprint)}">${escapeHtml(r.kind)}</a></td>
      <td>${escapeHtml(r.message)}</td>
      <td class="muted">${escapeHtml(r.source_file ?? "")}${r.source_line ? `:${escapeHtml(r.source_line)}` : ""}</td>
      <td>${renderCount(r.occurrence_count, r.count_is_floor === 1)}</td>
      <td class="muted">${escapeHtml(when(r.last_seen_at))}</td>
      <td>${escapeHtml(r.status)}</td>
    </tr>`,
      )
      .join("")}
  </tbody>
</table>
${rows.length === PAGE_SIZE ? `<p><a href="/admin/errors?page=${page + 1}${status ? `&status=${escapeHtml(status)}` : ""}">Next</a></p>` : ""}`;

    return c.html(layout("Errors", body));
  });

  app.get("/admin/errors/:fingerprint", async (c) => {
    const found = await getError(c.env, c.req.param("fingerprint"));
    if (!found) return c.html(layout("Not found", "<p>No such error group.</p>"), 404);

    const { error, occurrences } = found;

    // escapeHtml(error.fingerprint) in the <form action> below is the same
    // defense-in-depth as the list page's <a href> (see the comment there);
    // the fixed "/admin/errors/" prefix plus fingerprintOf's 32-hex-char output is
    // what actually makes it safe, not the escaping itself.
    const body = `
<p>
  <strong>${escapeHtml(error.kind)}</strong>: ${escapeHtml(error.message)}<br>
  <span class="muted">${renderCount(error.occurrence_count, error.count_is_floor === 1)} occurrences, first ${escapeHtml(when(error.first_seen_at))}, last ${escapeHtml(when(error.last_seen_at))}</span>
</p>
<form method="post" action="/admin/errors/${escapeHtml(error.fingerprint)}/${error.status === "resolved" ? "unresolve" : "resolve"}">
  <button type="submit">${error.status === "resolved" ? "Reopen" : "Resolve"}</button>
</form>
<h2>Recent occurrences</h2>
${occurrences
  .map(
    (o) => `<details>
  <summary>${escapeHtml(when(o.occurred_at))} &middot; ${escapeHtml(o.version ?? "unknown")} &middot; ${escapeHtml(o.environment ?? "")}</summary>
  <pre>${escapeHtml(o.stacktrace)}</pre>
  <pre>${escapeHtml(o.context)}</pre>
</details>`,
  )
  .join("")}`;

    return c.html(layout(error.kind, body));
  });

  // Both mutation routes validate the fingerprint's shape BEFORE touching D1
  // or building the redirect. A malformed segment here isn't hypothetical:
  // Hono's redirect() builds the Location header directly from the decoded
  // param, and a value containing a CRLF sequence (delivered URL-encoded,
  // e.g. `%0D%0A`) makes the underlying Headers implementation throw --
  // fails safe (no header injection actually lands), but as an unhandled
  // 500, not a clean 404, on an unauthenticated route. Rejecting anything
  // that isn't a real fingerprint's shape up front avoids both the wasted D1
  // round trip for garbage input and the 500.
  app.post("/admin/errors/:fingerprint/resolve", async (c) => {
    const fingerprint = c.req.param("fingerprint");
    if (!isValidFingerprintShape(fingerprint)) {
      return c.html(layout("Not found", "<p>No such error group.</p>"), 404);
    }
    await setErrorStatus(c.env, fingerprint, "resolved");
    return c.redirect(`/admin/errors/${fingerprint}`, 303);
  });

  app.post("/admin/errors/:fingerprint/unresolve", async (c) => {
    const fingerprint = c.req.param("fingerprint");
    if (!isValidFingerprintShape(fingerprint)) {
      return c.html(layout("Not found", "<p>No such error group.</p>"), 404);
    }
    await setErrorStatus(c.env, fingerprint, "unresolved");
    return c.redirect(`/admin/errors/${fingerprint}`, 303);
  });
}
