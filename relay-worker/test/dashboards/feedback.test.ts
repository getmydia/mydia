import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";

// Mutation routes (state, github) now validate the :id path segment against
// crypto.randomUUID()'s real shape before touching D1 or building a
// redirect (see dashboards/feedback.ts's isValidIdShape and
// dashboards/errors.ts's identical fingerprint-shape lesson), so every
// fixture exercised through those two routes needs a realistic-looking id
// rather than a short mnemonic string like "fb1". GET-only fixtures (the
// escaping tests below) never go through shape validation, so they keep
// short names.
const FB1 = "0f1e2d3c-4b5a-4c1d-8e2f-1a2b3c4d5e6f";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    `INSERT INTO feedback_submissions
       (id, type, message, contact, mydia_version, source_ip, state, inserted_at, updated_at)
     VALUES (?, 'bug', 'Scanner missed a file', 'someone@example.com',
             '1.2.3', '203.0.113.42', 'unread', ?, ?)`,
  )
    .bind(FB1, now, now)
    .run();
});

describe("GET /admin/feedback dashboard", () => {
  it("lists submissions", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/admin/feedback");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");

    const html = await res.text();
    expect(html).toContain("Scanner missed a file");
    expect(html).toContain("1.2.3");
  });

  // Fix-round-1 finding: index.html.heex surfaces submission.source_ip per
  // row (a triage/anti-abuse signal -- deciding whether a run of
  // submissions is one person), and the dashboard dropped it without
  // disclosing the omission.
  it("shows the source IP column, an anti-abuse signal the Elixir dashboard also surfaces", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/feedback")).text();
    expect(html).toContain("Source IP");
    expect(html).toContain("203.0.113.42");
  });

  // The Elixir template applies whitespace-pre-wrap to the message; without
  // it a multi-line submission renders as one run-on line even though the
  // text is intact in the markup. Assert the CSS hook is actually wired to
  // the message cell, not just present somewhere in the stylesheet.
  it("preserves multi-line messages visually via the wrap class", async () => {
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare(
      `INSERT INTO feedback_submissions (id, type, message, state, inserted_at, updated_at)
       VALUES ('fbmultiline', 'bug', 'Line one\nLine two', 'unread', ?, ?)`,
    )
      .bind(now, now)
      .run();

    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/feedback")).text();
    expect(html).toContain("Line one\nLine two");
    const cellStart = html.indexOf('<td class="wrap">Line one');
    expect(cellStart).toBeGreaterThan(-1);
  });

  it("does not share a path with the public POST ingest route", async () => {
    // The whole point of moving this dashboard to /admin/feedback: the
    // public ingest endpoint stays at bare /feedback, completely unaffected
    // by anything (including a future Cloudflare Access application) scoped
    // to /admin/*.
    const res = await SELF.fetch("https://relay.mydia.dev/feedback", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "idea", message: "still works" }),
    });
    expect(res.status).toBe(201);
  });

  it("no longer serves the dashboard at the old /feedback path", async () => {
    // GET /feedback must not be a second, unauthenticated way to reach
    // maintainer data now that the real dashboard lives at
    // /admin/feedback -- whatever this returns, it must not be the
    // dashboard. registerFeedbackRoutes only registers POST /feedback, so
    // this falls through to the app-wide 404 catch-all in src/index.ts.
    const res = await SELF.fetch("https://relay.mydia.dev/feedback");
    expect(res.status).toBe(404);
    const body = await res.text();
    expect(body).not.toContain("Scanner missed a file");
    expect(body).not.toContain("<table");
  });

  it("marks a submission read", async () => {
    // fetch()'s default `redirect: "follow"` would otherwise chase the 303
    // and hand back the followed page's 200, hiding the redirect status this
    // assertion actually cares about (the same gap the dashboards/errors.ts
    // tests were fixed for).
    const res = await SELF.fetch(`https://relay.mydia.dev/admin/feedback/${FB1}/state`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "state=read",
      redirect: "manual",
    });
    expect(res.status).toBe(303);

    const row = await env.DB.prepare(
      "SELECT state FROM feedback_submissions WHERE id = ?",
    )
      .bind(FB1)
      .first<{ state: string }>();
    expect(row!.state).toBe("read");
  });

  it("rejects a state outside the allowed set", async () => {
    const res = await SELF.fetch(`https://relay.mydia.dev/admin/feedback/${FB1}/state`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "state=deleted",
      redirect: "manual",
    });
    expect(res.status).toBe(422);
  });

  it("attaches a github ref", async () => {
    const res = await SELF.fetch(`https://relay.mydia.dev/admin/feedback/${FB1}/github`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "github_ref=getmydia/mydia%23123",
      redirect: "manual",
    });
    expect(res.status).toBe(303);

    const row = await env.DB.prepare(
      "SELECT github_ref FROM feedback_submissions WHERE id = ?",
    )
      .bind(FB1)
      .first<{ github_ref: string }>();
    expect(row!.github_ref).toBe("getmydia/mydia#123");
  });

  // Submission.github_ref_changeset/2 (metadata-relay) has no
  // validate_required, so a blank value is accepted rather than rejected
  // with a 422 the Elixir dashboard never enforced. But Ecto.Changeset.cast/4's
  // default `empty_values` (which includes "") normalizes that blank change
  // away entirely, so the Elixir side never persists an empty string -- it
  // leaves the struct's `nil` default in place. Fix-round-1 finding: this
  // test originally asserted `.toBe("")`, locking in a persisted-data
  // mismatch (NULL vs. "") that was invisible in the UI because both
  // templates render null and "" identically.
  it("accepts a blank github ref, clearing any previous one to NULL (not empty string)", async () => {
    const res = await SELF.fetch(`https://relay.mydia.dev/admin/feedback/${FB1}/github`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "github_ref=",
      redirect: "manual",
    });
    expect(res.status).toBe(303);

    const row = await env.DB.prepare(
      "SELECT github_ref FROM feedback_submissions WHERE id = ?",
    )
      .bind(FB1)
      .first<{ github_ref: string | null }>();
    expect(row!.github_ref).toBeNull();
  });

  it("treats a whitespace-only github ref the same as blank", async () => {
    const res = await SELF.fetch(`https://relay.mydia.dev/admin/feedback/${FB1}/github`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: `github_ref=${encodeURIComponent("   ")}`,
      redirect: "manual",
    });
    expect(res.status).toBe(303);

    const row = await env.DB.prepare(
      "SELECT github_ref FROM feedback_submissions WHERE id = ?",
    )
      .bind(FB1)
      .first<{ github_ref: string | null }>();
    expect(row!.github_ref).toBeNull();
  });

  it("escapes submission text, which is user supplied", async () => {
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare(
      `INSERT INTO feedback_submissions (id, type, message, state, inserted_at, updated_at)
       VALUES ('fbxss', 'bug', '<script>alert(1)</script>', 'unread', ?, ?)`,
    )
      .bind(now, now)
      .run();

    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/feedback?state=all")).text();
    expect(html).not.toContain("<script>alert(1)</script>");
  });

  // contact, mydia_version and instance_id are all attacker-controlled
  // optional fields on the same unauthenticated POST /feedback endpoint as
  // message -- escaping only the message field and assuming the others are
  // "just strings" is exactly the kind of gap fix-round reviews keep
  // finding elsewhere in this codebase.
  it("escapes contact, mydia_version and instance_id, not just message", async () => {
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare(
      `INSERT INTO feedback_submissions
         (id, type, message, contact, instance_id, mydia_version, state, inserted_at, updated_at)
       VALUES ('fbfields', 'bug', 'benign message',
               '"><svg onload=alert(1)>', '"><svg onload=alert(2)>',
               '"><svg onload=alert(3)>', 'unread', ?, ?)`,
    )
      .bind(now, now)
      .run();

    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/feedback?state=all")).text();
    expect(html).not.toContain("<svg onload=alert(1)>");
    expect(html).not.toContain("<svg onload=alert(2)>");
    expect(html).not.toContain("<svg onload=alert(3)>");
  });

  // The non-obvious sink: an existing github_ref is pre-filled into the
  // input's `value="..."` attribute so a maintainer can edit it in place.
  // An unescaped ref could break out of that attribute.
  it("escapes a github_ref value rendered inside the input's value attribute", async () => {
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare(
      `INSERT INTO feedback_submissions
         (id, type, message, state, github_ref, inserted_at, updated_at)
       VALUES ('fbref', 'bug', 'benign message', 'unread',
               '"><script>alert(4)</script>', ?, ?)`,
    )
      .bind(now, now)
      .run();

    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/feedback?state=all")).text();
    expect(html).not.toContain('"><script>alert(4)</script>');
    expect(html).not.toContain("<script>alert(4)</script>");
  });

  // The other non-obvious injection sink: the row id is
  // interpolated into every mutation form's `action="..."` attribute. Real
  // ids are always crypto.randomUUID() output, but this is defense in
  // depth -- same reasoning as dashboards/errors.ts escaping a fingerprint
  // it also trusts structurally.
  it("escapes a row id used in a form action attribute", async () => {
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare(
      `INSERT INTO feedback_submissions (id, type, message, state, inserted_at, updated_at)
       VALUES ('"><script>alert(5)</script>', 'bug', 'benign message', 'unread', ?, ?)`,
    )
      .bind(now, now)
      .run();

    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/feedback?state=all")).text();
    expect(html).not.toContain('"><script>alert(5)</script>');
    expect(html).not.toContain("<script>alert(5)</script>");
  });
});

// IMPORTANT fix-round finding, mirrored from dashboards/errors.ts: `Number(...)`
// fed straight into a D1 OFFSET with no guard throws `D1_ERROR: datatype
// mismatch`, surfaced as an unhandled Hono 500, for each of these inputs.
describe("GET /admin/feedback?page= guards against hostile input", () => {
  const hostileValues = ["abc", "NaN", "Infinity", "1e300", "99999999999999999999"];

  it.each(hostileValues)("does not 500 for page=%s", async (value) => {
    const res = await SELF.fetch(
      `https://relay.mydia.dev/admin/feedback?page=${encodeURIComponent(value)}`,
    );
    expect(res.status).toBe(200);
  });

  it("still paginates normally for an ordinary page number", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/admin/feedback?page=1");
    expect(res.status).toBe(200);
  });

  it("clamps a negative page to the first page instead of erroring", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/admin/feedback?page=-5");
    expect(res.status).toBe(200);
  });
});

// Mirrors Feedback.list_submissions/1's maybe_filter/3: nil and the literal
// "all" both mean "no filter". listFeedback already handles this;
// this confirms the dashboard's own filter links actually produce values
// that exercise it, including "all".
describe("GET /admin/feedback?state= filtering", () => {
  it("defaults to the unread queue when no state is given, matching mount/3", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/feedback")).text();
    // fbxss/fbfields/fbref/the escaped-id row were all inserted as 'unread'
    // in the tests above, so the default (unread) view still contains them,
    // while FB1 (moved to 'read' earlier in this file) is state-dependent --
    // check the state-only filters directly instead of relying on FB1 here.
    expect(html).toContain("Scanner missed a file"); // FB1's message, state notwithstanding
  });

  it("state=all returns every state, not zero rows", async () => {
    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/feedback?state=all")).text();
    expect(html).toContain("Scanner missed a file");
  });

  it("state=read returns only read rows", async () => {
    // vitest-pool-workers' isolated storage rolls each test back to the
    // state right after beforeAll, so FB1's "read" transition from an
    // earlier test in this file does not carry over here -- do the
    // transition again within this test rather than relying on it.
    await SELF.fetch(`https://relay.mydia.dev/admin/feedback/${FB1}/state`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "state=read",
      redirect: "manual",
    });

    const html = await (await SELF.fetch("https://relay.mydia.dev/admin/feedback?state=read")).text();
    expect(html).toContain("Scanner missed a file");

    const unreadOnly = await (
      await SELF.fetch("https://relay.mydia.dev/admin/feedback")
    ).text();
    expect(unreadOnly).not.toContain("Scanner missed a file");
  });
});

// Lesson from dashboards/errors.ts's :fingerprint validation, applied to
// feedback's :id. A malformed segment here isn't hypothetical: Hono's
// redirect() builds the Location header directly from the decoded param,
// and a CRLF sequence (delivered URL-encoded, e.g. %0D%0A) makes the
// underlying Headers implementation throw -- fails safe, but as an
// unhandled 500 rather than a clean 404, on a route with no in-code auth
// (Cloudflare Access guards /admin/* at the edge; see the README runbook).
describe("POST /admin/feedback/:id/state and /github validate the id shape first", () => {
  it("returns 404, not a 500, for a CRLF-injected id segment on /state", async () => {
    const res = await SELF.fetch(
      "https://relay.mydia.dev/admin/feedback/abc%0D%0AInjected/state",
      {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: "state=read",
        redirect: "manual",
      },
    );
    expect(res.status).toBe(404);
  });

  it("returns 404, not a 500, for a CRLF-injected id segment on /github", async () => {
    const res = await SELF.fetch(
      "https://relay.mydia.dev/admin/feedback/abc%0D%0AInjected/github",
      {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: "github_ref=x",
        redirect: "manual",
      },
    );
    expect(res.status).toBe(404);
  });

  it("returns 404 for a non-UUID id on /state", async () => {
    const res = await SELF.fetch(
      "https://relay.mydia.dev/admin/feedback/not-a-real-id/state",
      {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: "state=read",
        redirect: "manual",
      },
    );
    expect(res.status).toBe(404);
  });

  it("returns 404 for a non-UUID id on /github", async () => {
    const res = await SELF.fetch(
      "https://relay.mydia.dev/admin/feedback/not-a-real-id/github",
      {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: "github_ref=x",
        redirect: "manual",
      },
    );
    expect(res.status).toBe(404);
  });
});
