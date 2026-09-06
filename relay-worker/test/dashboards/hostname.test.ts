import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

// Cloudflare Access is configured per hostname: the runbook's Step 1
// application covers `relay.mydia.dev/admin*` and nothing else. The Worker is
// ALSO live on its `*.workers.dev` subdomain from the first successful CI
// deploy, plus the versioned preview URLs alongside it, and Access never sees
// those requests -- so without this deny the maintainer dashboards would be
// anonymously readable there for the whole window between the first deploy
// and the Step 4 cutover.
//
// This is not authentication and these tests do not claim it is. It removes an
// unprotected hostname from reach; Access still decides who may look.
describe("/admin/* on a workers.dev hostname", () => {
  const ADMIN_PATHS = ["/admin/errors", "/admin/feedback"];

  // Mirrors vitest.config.ts's miniflare binding. The deliberately different
  // worker name (`-staging`) is what keeps every pre-existing case in this
  // file valid: they all use `mydia-relay.someacct.workers.dev`, which is not
  // this hostname and must still 404.
  const ACCESS_HOSTNAME = "mydia-relay-staging.someacct.workers.dev";

  for (const path of ADMIN_PATHS) {
    it(`answers 404 for ${path} on the deploy subdomain`, async () => {
      const res = await SELF.fetch(`https://mydia-relay.someacct.workers.dev${path}`);

      expect(res.status).toBe(404);
      const body = await res.text();
      expect(body).not.toContain("<table");
    });

    it(`answers 404 for ${path} on a versioned preview URL`, async () => {
      const res = await SELF.fetch(
        `https://a1b2c3-mydia-relay.someacct.workers.dev${path}`,
      );

      expect(res.status).toBe(404);
    });

    it(`still serves ${path} on the production hostname, where Access is the gate`, async () => {
      const res = await SELF.fetch(`https://relay.mydia.dev${path}`);

      expect(res.status).toBe(200);
    });

    it(`serves ${path} on the Access-guarded staging hostname`, async () => {
      const res = await SELF.fetch(`https://${ACCESS_HOSTNAME}${path}`);

      expect(res.status).toBe(200);
    });

    // The case that matters most. A per-hostname Access application does not
    // cover the versioned preview URLs Cloudflare mints alongside every
    // deploy, so they must keep 404ing even though their suffix matches the
    // hostname that is allowed.
    it(`still answers 404 for ${path} on a preview URL of that hostname`, async () => {
      const res = await SELF.fetch(`https://a1b2c3-${ACCESS_HOSTNAME}${path}`);

      expect(res.status).toBe(404);
    });
  }

  // The mutation routes live under /admin/* too, and a deny that only covered
  // the two GET dashboards would leave them reachable.
  it("covers the dashboard mutation routes, not just the list pages", async () => {
    const res = await SELF.fetch(
      "https://mydia-relay.someacct.workers.dev/admin/errors/a1b2c3d4e5f60718293a4b5c6d7e8f90/resolve",
      { method: "POST" },
    );

    expect(res.status).toBe(404);
  });

  // The public ingest routes every mydia install already calls must keep
  // working on every hostname -- they are not under /admin and must never be
  // caught by this.
  it("leaves the public ingest routes reachable on workers.dev", async () => {
    const res = await SELF.fetch("https://mydia-relay.someacct.workers.dev/health");

    expect(res.status).toBe(200);
    expect(await res.json<{ status: string }>()).toMatchObject({ status: "ok" });
  });
});
