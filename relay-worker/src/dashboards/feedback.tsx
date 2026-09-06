import type { Hono } from "hono";
import type { Env } from "../env";
import type { FeedbackRow } from "../feedback/ingest";
import { listFeedback, setFeedbackState, setGithubRef } from "../feedback/queries";
import { page, when, parsePage } from "./layout";
import { Tabs, DataTable, PostButton, Pager } from "./ui";

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

// Every real feedback id is crypto.randomUUID() output (validateSubmission
// in feedback/ingest.ts), the same shape Ecto.UUID.cast/1 requires of
// Feedback.get_submission/1's :id argument on the Elixir side. Anything
// else in the :id path segment cannot be a real submission, and letting it
// through to c.redirect() risks the same CRLF -> unhandled-500-in-Headers
// failure dashboards/errors.tsx already guards against for :fingerprint.
// Validate before touching D1 or building a redirect.
const UUID_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isValidIdShape(value: string): boolean {
  return UUID_SHAPE.test(value);
}

const NOT_FOUND_BODY = <p>No such feedback submission.</p>;

const HEADERS = [
  "When",
  "Type",
  "Message",
  "Version",
  "Contact",
  "Instance",
  "Source IP",
  "State",
  "GitHub",
];

// Mirrors index.html.heex's contextual buttons: "mark read" only shows for
// an unread row, "archive" only for a not-yet-archived row. Neither the
// Elixir dashboard nor this one exposes a generic "switch to any other
// state" control per row.
//
// `{cond && <PostButton/>}` is the right idiom here: hono/jsx drops false,
// null and undefined children, so a hidden button renders nothing at all.
function FeedbackTableRow({ row }: { row: FeedbackRow }) {
  return (
    <tr>
      <td class="muted num">{when(row.inserted_at)}</td>
      <td>{row.type}</td>
      <td class="wrap">{row.message}</td>
      <td class="muted">{row.mydia_version ?? ""}</td>
      <td class="muted">{row.contact ?? ""}</td>
      <td class="muted">{row.instance_id ?? ""}</td>
      <td class="muted">{row.source_ip ?? ""}</td>
      <td>
        {row.state}{" "}
        {row.state === "unread" && (
          <PostButton
            action={`/admin/feedback/${row.id}/state`}
            label="mark read"
            fields={{ state: "read" }}
          />
        )}{" "}
        {row.state !== "archived" && (
          <PostButton
            action={`/admin/feedback/${row.id}/state`}
            label="archive"
            fields={{ state: "archived" }}
          />
        )}
      </td>
      <td>
        <form method="post" action={`/admin/feedback/${row.id}/github`}>
          <input
            type="text"
            name="github_ref"
            placeholder="owner/repo#123"
            value={row.github_ref ?? ""}
            size={16}
          />
          <button type="submit">save</button>
        </form>
      </td>
    </tr>
  );
}

function FeedbackPage({
  rows,
  state,
  page: pageNumber,
}: {
  rows: FeedbackRow[];
  state: FeedbackState | "all";
  page: number;
}) {
  // Uses encodeURIComponent, not escapeHtml, for consistency with the errors
  // dashboard's pager (same substitution there). Here it's inert: `state` is
  // the closed union FeedbackState | "all", so no value differs under either
  // encoding. errors.tsx's `status` is unvalidated query input, which is why
  // it matters there -- see that file's ErrorsPage comment for the mechanism.
  const next =
    rows.length === PAGE_SIZE
      ? `/admin/feedback?page=${pageNumber + 1}&state=${encodeURIComponent(state)}`
      : null;

  return (
    <>
      <Tabs
        links={[
          { href: "/admin/feedback", label: "unread", active: state === "unread" },
          { href: "/admin/feedback?state=read", label: "read", active: state === "read" },
          { href: "/admin/feedback?state=archived", label: "archived", active: state === "archived" },
          { href: "/admin/feedback?state=all", label: "all", active: state === "all" },
        ]}
      />
      <DataTable headers={HEADERS}>
        {rows.map((row) => (
          <FeedbackTableRow row={row} />
        ))}
      </DataTable>
      <Pager href={next} />
    </>
  );
}

export function registerFeedbackDashboard(app: Hono<{ Bindings: Env }>): void {
  app.get("/admin/feedback", async (c) => {
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
    const pageNumber = parsePage(c.req.query("page"));

    const rows = await listFeedback(c.env, {
      state,
      limit: PAGE_SIZE,
      offset: pageNumber * PAGE_SIZE,
    });

    return c.html(
      page("Feedback", <FeedbackPage rows={rows} state={state} page={pageNumber} />),
    );
  });

  app.post("/admin/feedback/:id/state", async (c) => {
    const id = c.req.param("id");
    if (!isValidIdShape(id)) {
      return c.html(page("Not found", NOT_FOUND_BODY), 404);
    }

    const form = await c.req.formData();
    const rawState = String(form.get("state") ?? "");
    if (!isValidState(rawState)) {
      return c.json({ errors: [`state must be one of ${STATES.join(", ")}`] }, 422);
    }

    await setFeedbackState(c.env, id, rawState);
    return c.redirect("/admin/feedback", 303);
  });

  app.post("/admin/feedback/:id/github", async (c) => {
    const id = c.req.param("id");
    if (!isValidIdShape(id)) {
      return c.html(page("Not found", NOT_FOUND_BODY), 404);
    }

    const form = await c.req.formData();
    // Mirrors Submission.github_ref_changeset/2: no validate_required, so a
    // blank value is accepted (clearing a previously attached ref), not
    // rejected with a 422 the Elixir side never had. setGithubRef itself
    // normalizes a blank/whitespace-only value to NULL, matching what
    // Ecto.Changeset.cast/4's default empty_values does on the Elixir side.
    const ref = String(form.get("github_ref") ?? "");
    await setGithubRef(c.env, id, ref);
    return c.redirect("/admin/feedback", 303);
  });
}
