import type { Hono } from "hono";
import type { Env } from "../env";
import type { ErrorRow, OccurrenceRow } from "../crashes/ingest";
import { listErrors, getError, setErrorStatus } from "../crashes/queries";
import { page, when, parsePage } from "./layout";
import { Tabs, DataTable, Badge, PostButton, Pager } from "./ui";

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

const FLOOR_TITLE =
  "The ingest throttle saturated at least one hourly bucket for this error at " +
  "some point. Crashes beyond the per-hour cap were accepted but not counted, " +
  "so this total is a permanent floor, not an exact count.";

// The single place a raw occurrence_count is turned into markup. When
// errors.count_is_floor is set (ingest.ts sets it the moment any of this
// fingerprint's buckets ever saturates, and never clears it -- see
// 0002_crash_reports.sql), occurrence_count is a FLOOR, not an exact total:
// rendering it as a bare number would present a throttled undercount as if
// it were precise, worst exactly during the crash storm an operator is
// trying to understand. The "≥" and the visible badge are the distinguishing
// signal.
//
// Note the literal "≥" and "&#160;" below. Writing "&ge;&nbsp;" as a JSX
// string child would render as "&amp;ge;&amp;nbsp;" -- hono/jsx escapes
// child text, so an HTML entity in a plain string double-escapes.
function Count({ count, isFloor }: { count: number; isFloor: boolean }) {
  const value = formatInteger(count);
  if (!isFloor) return <>{value}</>;
  return (
    <span class="num">
      ≥&#160;{value}
      <Badge label="throttled" title={FLOOR_TITLE} />
    </span>
  );
}

function sourceRef(error: ErrorRow): string {
  const file = error.source_file ?? "";
  return error.source_line ? `${file}:${error.source_line}` : file;
}

// The href below interpolates a fingerprint straight into a path. hono/jsx
// escapes it, but escaping is NOT what makes it safe: it neutralises HTML
// metacharacters, not URL-structural ones (a slash, "?", "#", a raw CRLF).
// What makes it safe is that the path prefix is the fixed literal
// "/admin/errors/" and fingerprintOf's output is constrained to 32 lowercase
// hex characters. If fingerprint generation ever allows arbitrary bytes,
// this href needs its own encodeURIComponent, and JSX will not tell you.
function ErrorTableRow({ error }: { error: ErrorRow }) {
  return (
    <tr>
      <td>
        <a href={`/admin/errors/${error.fingerprint}`}>{error.kind}</a>
      </td>
      <td class="wrap">{error.message}</td>
      <td class="muted">{sourceRef(error)}</td>
      <td class="num">
        <Count count={error.occurrence_count} isFloor={error.count_is_floor === 1} />
      </td>
      <td class="muted num">{when(error.last_seen_at)}</td>
      <td>{error.status}</td>
    </tr>
  );
}

const HEADERS = ["Kind", "Message", "Source", "Count", "Last seen", "Status"];

function ErrorsPage({
  rows,
  status,
  page: pageNumber,
}: {
  rows: ErrorRow[];
  status: string | undefined;
  page: number;
}) {
  const next =
    rows.length === PAGE_SIZE
      ? `/admin/errors?page=${pageNumber + 1}${status ? `&status=${encodeURIComponent(status)}` : ""}`
      : null;

  return (
    <>
      <Tabs
        links={[
          { href: "/admin/errors", label: "all", active: status === undefined },
          { href: "/admin/errors?status=unresolved", label: "unresolved", active: status === "unresolved" },
          { href: "/admin/errors?status=resolved", label: "resolved", active: status === "resolved" },
        ]}
      />
      <DataTable headers={HEADERS}>
        {rows.map((error) => (
          <ErrorTableRow error={error} />
        ))}
      </DataTable>
      <Pager href={next} />
    </>
  );
}

function OccurrenceDetails({ occurrence }: { occurrence: OccurrenceRow }) {
  return (
    <details>
      <summary>
        {when(occurrence.occurred_at)} &middot; {occurrence.version ?? "unknown"} &middot;{" "}
        {occurrence.environment ?? ""}
      </summary>
      <pre>{occurrence.stacktrace}</pre>
      <pre>{occurrence.context}</pre>
    </details>
  );
}

// The form action carries the same fixed-prefix-plus-constrained-shape
// reasoning as ErrorTableRow's href above.
function ErrorDetailPage({
  error,
  occurrences,
}: {
  error: ErrorRow;
  occurrences: OccurrenceRow[];
}) {
  const resolved = error.status === "resolved";
  return (
    <>
      <p>
        <strong>{error.kind}</strong>: {error.message}
        <br />
        <span class="muted">
          <Count count={error.occurrence_count} isFloor={error.count_is_floor === 1} /> occurrences,
          first {when(error.first_seen_at)}, last {when(error.last_seen_at)}
        </span>
      </p>
      <PostButton
        action={`/admin/errors/${error.fingerprint}/${resolved ? "unresolve" : "resolve"}`}
        label={resolved ? "Reopen" : "Resolve"}
      />
      <h2>Recent occurrences</h2>
      {occurrences.map((occurrence) => (
        <OccurrenceDetails occurrence={occurrence} />
      ))}
    </>
  );
}

export function registerErrorDashboard(app: Hono<{ Bindings: Env }>): void {
  app.get("/admin/errors", async (c) => {
    const status = c.req.query("status") ?? undefined;
    const pageNumber = parsePage(c.req.query("page"));
    const rows = await listErrors(c.env, {
      status,
      limit: PAGE_SIZE,
      offset: pageNumber * PAGE_SIZE,
    });

    return c.html(page("Errors", <ErrorsPage rows={rows} status={status} page={pageNumber} />));
  });

  app.get("/admin/errors/:fingerprint", async (c) => {
    const found = await getError(c.env, c.req.param("fingerprint"));
    if (!found) return c.html(page("Not found", <p>No such error group.</p>), 404);

    const { error, occurrences } = found;
    return c.html(
      page(error.kind, <ErrorDetailPage error={error} occurrences={occurrences} />),
    );
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
      return c.html(page("Not found", <p>No such error group.</p>), 404);
    }
    await setErrorStatus(c.env, fingerprint, "resolved");
    return c.redirect(`/admin/errors/${fingerprint}`, 303);
  });

  app.post("/admin/errors/:fingerprint/unresolve", async (c) => {
    const fingerprint = c.req.param("fingerprint");
    if (!isValidFingerprintShape(fingerprint)) {
      return c.html(page("Not found", <p>No such error group.</p>), 404);
    }
    await setErrorStatus(c.env, fingerprint, "unresolved");
    return c.redirect(`/admin/errors/${fingerprint}`, 303);
  });
}
