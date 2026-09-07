import type { Hono } from "hono";
import type { Env } from "../env";
import {
  loadOverviewStats,
  parseWindow,
  WINDOWS,
  type OverviewStats,
  type WindowKey,
} from "../stats/queries";
import { page, when } from "./layout";
import { Tabs, DataTable, Badge, StatGrid, StatCard, FLOOR_TITLE } from "./ui";

// occurrences.instance_key holds cf-connecting-ip, falling back to the crash
// report's version string and then to the literal "unknown" (see
// crashes/ingest.ts). It was chosen as a rate-limiting key and carries no
// identity, so this number is emphatically not an install count. Only the
// count renders; the addresses themselves stay in D1.
const SOURCES_HINT =
  "IP-derived, so this undercounts installs behind one NAT and overcounts " +
  "one install on a changing address.";

// Every count on this page goes through here. loadOverviewStats already
// coerces a missing aggregate to 0, so this is the second line of defence:
// one unreadable value blanks one card instead of rendering NaN across the
// page.
function count(value: number | null | undefined): string {
  return typeof value === "number" && Number.isFinite(value)
    ? String(value)
    : "—";
}

const WINDOW_LABELS: Record<WindowKey, string> = {
  "24h": "24h",
  "7d": "7d",
  "30d": "30d",
};

const VERSION_HEADERS = ["Version", "Occurrences", "Sources"];
const TOP_ERROR_HEADERS = ["Error", "In window", "Last seen"];
const TABLE_HEADERS = ["Table", "Rows"];

function windowTabs(active: WindowKey) {
  return (
    <Tabs
      links={(Object.keys(WINDOWS) as WindowKey[]).map((key) => ({
        href: `/admin?window=${key}`,
        label: WINDOW_LABELS[key],
        active: key === active,
      }))}
    />
  );
}

function LastSweep({ stats }: { stats: OverviewStats }) {
  if (!stats.lastSweep) {
    return (
      <p class="muted">
        Last sweep: never. The hourly Cron Trigger has not run since this table
        was added.
      </p>
    );
  }

  const run = stats.lastSweep;
  return (
    <p class="muted">
      Last sweep: {when(run.ran_at)} UTC, {count(run.duration_ms)}ms, deleting{" "}
      {count(run.feedback_rate_limits_deleted)} rate-limit,{" "}
      {count(run.ingest_buckets_deleted)} ingest-bucket and{" "}
      {count(run.pairing_claims_deleted)} pairing rows.
    </p>
  );
}

function OverviewPage({ stats }: { stats: OverviewStats }) {
  const unread = stats.feedbackByState.unread ?? 0;
  const feedbackTypes = Object.entries(stats.feedbackByType)
    .map(([type, n]) => `${type} ${n}`)
    .join(", ");

  return (
    <>
      {windowTabs(stats.window)}

      <StatGrid>
        <StatCard
          label="Crashes"
          value={count(stats.crashes)}
          badge={
            stats.throttledGroups > 0 ? (
              <Badge label="throttled" title={FLOOR_TITLE} />
            ) : undefined
          }
          hint={
            stats.throttledGroups > 0
              ? `${stats.throttledGroups} unresolved group(s) hit the hourly ingest cap, so this is a floor.`
              : undefined
          }
        />
        <StatCard
          label="Crash sources"
          value={count(stats.crashSources)}
          hint={SOURCES_HINT}
        />
        <StatCard label="Unresolved groups" value={count(stats.unresolvedGroups)} />
        <StatCard
          label="Unread feedback"
          value={count(unread)}
          hint={feedbackTypes === "" ? undefined : `In window: ${feedbackTypes}`}
        />
        <StatCard
          label="Live pairing claims"
          value={count(stats.livePairingClaims)}
        />
      </StatGrid>

      <h2>Top unresolved errors</h2>
      <DataTable headers={TOP_ERROR_HEADERS}>
        {stats.topErrors.map((error) => (
          <tr>
            <td class="wrap">
              <a href={`/admin/errors/${error.fingerprint}`}>{error.kind}</a>{" "}
              {error.message}
              {error.count_is_floor === 1 && (
                <Badge label="throttled" title={FLOOR_TITLE} />
              )}
            </td>
            <td class="num">{count(error.recent)}</td>
            <td class="muted num">{when(error.last_seen_at)}</td>
          </tr>
        ))}
      </DataTable>

      <h2>Versions</h2>
      <DataTable headers={VERSION_HEADERS}>
        {stats.versions.map((row) => (
          <tr>
            <td>{row.version}</td>
            <td class="num">{count(row.occurrences)}</td>
            <td class="num">{count(row.sources)}</td>
          </tr>
        ))}
      </DataTable>

      <h2>Service health</h2>
      <DataTable headers={TABLE_HEADERS}>
        {Object.entries(stats.tableCounts).map(([table, n]) => (
          <tr>
            <td>{table}</td>
            <td class="num">{count(n)}</td>
          </tr>
        ))}
      </DataTable>
      <LastSweep stats={stats} />
    </>
  );
}

// GET /admin, the maintainer overview. It is the landing page for the other
// two dashboards, which is why it sits at the bare prefix rather than at
// /admin/stats: typing /admin used to reach the JSON 404 catch-all.
//
// The /admin/* hostname guard in src/index.ts covers this path. That was
// measured against Hono 4.13.7 rather than assumed, and
// test/dashboards/hostname.test.ts pins it, because a router change that
// stopped matching the bare path would start serving this page on
// production's workers.dev host and on every versioned preview URL.
export function registerOverviewDashboard(app: Hono<{ Bindings: Env }>): void {
  app.get("/admin", async (c) => {
    const window = parseWindow(c.req.query("window"));
    const stats = await loadOverviewStats(c.env, window);
    return c.html(page("Overview", <OverviewPage stats={stats} />));
  });
}
