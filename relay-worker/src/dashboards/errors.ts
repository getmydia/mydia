import type { Hono } from "hono";
import type { Env } from "../env";
import { listErrors, getError, setErrorStatus, getSaturatedFingerprints } from "../crashes/queries";
import { layout, escapeHtml } from "./layout";

const PAGE_SIZE = 50;

function when(unix: number): string {
  return new Date(unix * 1000).toISOString().replace("T", " ").slice(0, 19);
}

function formatInteger(n: number): string {
  return Math.trunc(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

// The single place a raw occurrence_count is turned into markup. When the
// ingest throttle has ever saturated one of this fingerprint's buckets,
// occurrence_count is a FLOOR, not an exact total (see queries.ts's
// getSaturatedFingerprints) -- rendering it as a bare number would present a
// throttled undercount as if it were precise, worst exactly during the crash
// storm an operator is trying to understand. "&ge;" plus a visible
// "throttled" badge is the distinguishing signal; nothing here is
// attacker-controlled (occurrence_count is an integer column, the label
// text is a fixed string) but it is still routed through escapeHtml for the
// same reason every other interpolated value in this file is: never special
// case a value here just because it looks safe today.
function renderCount(count: number, saturated: boolean): string {
  const value = escapeHtml(formatInteger(count));
  if (!saturated) return value;
  return `<span class="floor">&ge;&nbsp;${value}<span class="badge" title="The ingest throttle saturated at least one hourly bucket for this error. Crashes beyond the per-hour cap were accepted but not counted, so this total is a floor, not an exact count.">throttled</span></span>`;
}

export function registerErrorDashboard(app: Hono<{ Bindings: Env }>): void {
  app.get("/errors", async (c) => {
    const status = c.req.query("status") ?? undefined;
    const page = Number(c.req.query("page") ?? "0");
    const rows = await listErrors(c.env, {
      status,
      limit: PAGE_SIZE,
      offset: page * PAGE_SIZE,
    });
    const saturated = await getSaturatedFingerprints(
      c.env,
      rows.map((r) => r.fingerprint),
    );

    const body = `
<p class="muted">
  <a href="/errors">all</a>
  <a href="/errors?status=unresolved">unresolved</a>
  <a href="/errors?status=resolved">resolved</a>
</p>
<table>
  <thead><tr><th>Kind</th><th>Message</th><th>Source</th><th>Count</th><th>Last seen</th><th>Status</th></tr></thead>
  <tbody>
    ${rows
      .map(
        (r) => `<tr>
      <td><a href="/errors/${escapeHtml(r.fingerprint)}">${escapeHtml(r.kind)}</a></td>
      <td>${escapeHtml(r.message)}</td>
      <td class="muted">${escapeHtml(r.source_file ?? "")}${r.source_line ? `:${escapeHtml(r.source_line)}` : ""}</td>
      <td>${renderCount(r.occurrence_count, saturated.has(r.fingerprint))}</td>
      <td class="muted">${escapeHtml(when(r.last_seen_at))}</td>
      <td>${escapeHtml(r.status)}</td>
    </tr>`,
      )
      .join("")}
  </tbody>
</table>
${rows.length === PAGE_SIZE ? `<p><a href="/errors?page=${page + 1}${status ? `&status=${escapeHtml(status)}` : ""}">Next</a></p>` : ""}`;

    return c.html(layout("Errors", body));
  });

  app.get("/errors/:fingerprint", async (c) => {
    const found = await getError(c.env, c.req.param("fingerprint"));
    if (!found) return c.html(layout("Not found", "<p>No such error group.</p>"), 404);

    const { error, occurrences } = found;
    const saturated = (await getSaturatedFingerprints(c.env, [error.fingerprint])).has(
      error.fingerprint,
    );

    const body = `
<p>
  <strong>${escapeHtml(error.kind)}</strong>: ${escapeHtml(error.message)}<br>
  <span class="muted">${renderCount(error.occurrence_count, saturated)} occurrences, first ${escapeHtml(when(error.first_seen_at))}, last ${escapeHtml(when(error.last_seen_at))}</span>
</p>
<form method="post" action="/errors/${escapeHtml(error.fingerprint)}/${error.status === "resolved" ? "unresolve" : "resolve"}">
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

  app.post("/errors/:fingerprint/resolve", async (c) => {
    await setErrorStatus(c.env, c.req.param("fingerprint"), "resolved");
    return c.redirect(`/errors/${c.req.param("fingerprint")}`, 303);
  });

  app.post("/errors/:fingerprint/unresolve", async (c) => {
    await setErrorStatus(c.env, c.req.param("fingerprint"), "unresolved");
    return c.redirect(`/errors/${c.req.param("fingerprint")}`, 303);
  });
}
