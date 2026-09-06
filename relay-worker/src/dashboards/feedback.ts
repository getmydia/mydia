import type { Hono } from "hono";
import type { Env } from "../env";
import { listFeedback, setFeedbackState, setGithubRef } from "../feedback/queries";
import { layout, escapeHtml } from "./layout";

const PAGE_SIZE = 50;

// Mirrors Submission.@states (metadata-relay/lib/metadata_relay/feedback/submission.ex)
// and state_changeset/2's validate_inclusion -- these three are the only
// values D1's UPDATE below (via setFeedbackState) is allowed to write.
const STATES = ["unread", "read", "archived"] as const;
type FeedbackState = (typeof STATES)[number];

function isValidState(value: string): value is FeedbackState {
  return (STATES as readonly string[]).includes(value);
}

// Mirrors FeedbackLive.Index's mount/3: landing on the dashboard with no
// explicit filter shows the unread queue first, not the entire history. The
// literal "all" (queries.ts's listFeedback, matching
// Feedback.list_submissions/1's maybe_filter/3) is what turns the filter
// off entirely.
const DEFAULT_STATE_FILTER: FeedbackState = "unread";

// Same reasoning as dashboards/errors.ts's MAX_PAGE / parsePage: ?page= is
// arbitrary caller-supplied text on an unauthenticated route.
// `Number("abc")`/`Number("NaN")`/`Number("Infinity")`/`Number("1e300")`
// each produce a value that reaches D1 as an OFFSET and throws
// `D1_ERROR: datatype mismatch`, surfaced as an unhandled Hono 500.
const MAX_PAGE = 100_000;

function parsePage(raw: string | undefined): number {
  if (raw === undefined) return 0;
  const n = Number(raw);
  if (!Number.isSafeInteger(n) || n < 0) return 0;
  return Math.min(n, MAX_PAGE);
}

// Every real feedback id is crypto.randomUUID() output (validateSubmission
// in feedback/ingest.ts), the same shape Ecto.UUID.cast/1 requires of
// Feedback.get_submission/1's :id argument on the Elixir side. Anything
// else in the :id path segment cannot be a real submission, and letting it
// through to c.redirect() risks the same CRLF -> unhandled-500-in-Headers
// failure dashboards/errors.ts already hit for :fingerprint. Validate
// before touching D1 or building a redirect.
const UUID_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isValidIdShape(value: string): boolean {
  return UUID_SHAPE.test(value);
}

function when(unix: number): string {
  return new Date(unix * 1000).toISOString().replace("T", " ").slice(0, 19);
}

const NOT_FOUND_BODY = "<p>No such feedback submission.</p>";

export function registerFeedbackDashboard(app: Hono<{ Bindings: Env }>): void {
  app.get("/feedback", async (c) => {
    const rawState = c.req.query("state");
    // Mirrors normalize_state_filter/1: no param at all defaults to
    // "unread"; a recognised value (including the literal "all") is used
    // as-is; anything unrecognised falls back to "all" rather than
    // rejecting a bookmarked or hand-edited URL outright.
    const state: FeedbackState | "all" =
      rawState === undefined
        ? DEFAULT_STATE_FILTER
        : rawState === "all" || isValidState(rawState)
          ? rawState
          : "all";
    const page = parsePage(c.req.query("page"));

    const rows = await listFeedback(c.env, {
      state,
      limit: PAGE_SIZE,
      offset: page * PAGE_SIZE,
    });

    const body = `
<p class="muted">
  <a href="/feedback">unread</a>
  <a href="/feedback?state=read">read</a>
  <a href="/feedback?state=archived">archived</a>
  <a href="/feedback?state=all">all</a>
</p>
<table>
  <thead><tr><th>When</th><th>Type</th><th>Message</th><th>Version</th><th>Contact</th><th>Instance</th><th>State</th><th>GitHub</th></tr></thead>
  <tbody>
    ${rows
      .map((r) => {
        // Mirrors index.html.heex's contextual buttons: "Mark read" only
        // shows for an unread row, "Archive" only for a not-yet-archived
        // row -- neither the Elixir dashboard nor this one exposes a
        // generic "switch to any other state" control per row.
        const markReadForm = `<form method="post" action="/feedback/${escapeHtml(r.id)}/state">
              <input type="hidden" name="state" value="read">
              <button type="submit">mark read</button>
            </form>`;
        const archiveForm = `<form method="post" action="/feedback/${escapeHtml(r.id)}/state">
              <input type="hidden" name="state" value="archived">
              <button type="submit">archive</button>
            </form>`;

        return `<tr>
      <td class="muted">${escapeHtml(when(r.inserted_at))}</td>
      <td>${escapeHtml(r.type)}</td>
      <td>${escapeHtml(r.message)}</td>
      <td class="muted">${escapeHtml(r.mydia_version ?? "")}</td>
      <td class="muted">${escapeHtml(r.contact ?? "")}</td>
      <td class="muted">${escapeHtml(r.instance_id ?? "")}</td>
      <td>
        ${escapeHtml(r.state)}
        ${r.state === "unread" ? markReadForm : ""}
        ${r.state !== "archived" ? archiveForm : ""}
      </td>
      <td>
        <form method="post" action="/feedback/${escapeHtml(r.id)}/github">
          <input name="github_ref" placeholder="owner/repo#123" value="${escapeHtml(r.github_ref ?? "")}" size="16">
          <button type="submit">save</button>
        </form>
      </td>
    </tr>`;
      })
      .join("")}
  </tbody>
</table>
${rows.length === PAGE_SIZE ? `<p><a href="/feedback?page=${page + 1}&state=${escapeHtml(state)}">Next</a></p>` : ""}`;

    return c.html(layout("Feedback", body));
  });

  app.post("/feedback/:id/state", async (c) => {
    const id = c.req.param("id");
    if (!isValidIdShape(id)) {
      return c.html(layout("Not found", NOT_FOUND_BODY), 404);
    }

    const form = await c.req.formData();
    const rawState = String(form.get("state") ?? "");
    if (!isValidState(rawState)) {
      return c.json({ errors: [`state must be one of ${STATES.join(", ")}`] }, 422);
    }

    await setFeedbackState(c.env, id, rawState);
    return c.redirect("/feedback", 303);
  });

  app.post("/feedback/:id/github", async (c) => {
    const id = c.req.param("id");
    if (!isValidIdShape(id)) {
      return c.html(layout("Not found", NOT_FOUND_BODY), 404);
    }

    const form = await c.req.formData();
    // Mirrors Submission.github_ref_changeset/2: no validate_required, so a
    // blank value is accepted and stored as-is (clearing a previously
    // attached ref), not rejected with a 422 the Elixir side never had.
    const ref = String(form.get("github_ref") ?? "");
    await setGithubRef(c.env, id, ref);
    return c.redirect("/feedback", 303);
  });
}
