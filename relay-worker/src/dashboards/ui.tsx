import type { Child } from "hono/jsx";

// Presentational only. Nothing here touches D1, the Env, or the request.
// Every text and attribute value is escaped by hono/jsx on the way out, so
// these components are safe to hand crash- and feedback-derived strings.
//
// Note for anyone extending these: do NOT add a `key` prop to any mapped
// element. hono/jsx is not React and renders `key` as a literal attribute
// into the response body.

export interface TabLink {
  href: string;
  label: string;
  active: boolean;
}

// The filter row on both dashboards. Which tab is active is decided
// server-side from the query string; there is no client JS to do it.
// aria-current is what makes the active tab announceable, and the stylesheet
// hangs the active styling off the same attribute rather than a class, so
// the two can never disagree.
export function Tabs({ links }: { links: TabLink[] }) {
  return (
    <nav class="tabs">
      {links.map((link) => (
        <a href={link.href} aria-current={link.active ? "page" : undefined}>
          {link.label}
        </a>
      ))}
    </nav>
  );
}

// Both dashboards' tables are wide (six and nine columns). .table-wrap is an
// overflow-x container so a narrow viewport scrolls the table instead of the
// whole page.
export function DataTable({ headers, children }: { headers: string[]; children?: Child }) {
  return (
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            {headers.map((h) => (
              <th>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  );
}

export function Badge({ label, title }: { label: string; title: string }) {
  return (
    <span class="badge" title={title}>
      {label}
    </span>
  );
}

// The single explanation of what a "throttled" badge means, shared by the
// errors dashboard (where it hangs off one error's total) and the overview
// (where it hangs off the aggregate crash count). One constant rather than a
// copy in each, so the two can never drift into describing the same
// mechanism differently.
export const FLOOR_TITLE =
  "The ingest throttle saturated at least one hourly bucket at some point. " +
  "Crashes beyond the per-hour cap were accepted but not counted, so this " +
  "total is a permanent floor, not an exact count.";

// A single-button POST form. Used for resolve/unresolve on the errors
// dashboard and mark-read/archive on the feedback one. Kept as a real form
// rather than a fetch() so the dashboards keep working with JS disabled,
// which is also why every mutation answers 303 rather than returning JSON.
export function PostButton({
  action,
  label,
  fields,
}: {
  action: string;
  label: string;
  fields?: Record<string, string>;
}) {
  return (
    <form method="post" action={action}>
      {Object.entries(fields ?? {}).map(([name, value]) => (
        <input type="hidden" name={name} value={value} />
      ))}
      <button type="submit">{label}</button>
    </form>
  );
}

// Returns null (rendering nothing) rather than an empty <p> when there is no
// next page, so the caller can pass a nullable href unconditionally.
export function Pager({ href }: { href: string | null }) {
  if (!href) return null;
  return (
    <p class="pager">
      <a href={href}>Next</a>
    </p>
  );
}

// The overview's headline row. Purely a layout container: it applies no
// meaning to its children and does not decide how many fit, which is
// grid-template-columns' job in styles.ts.
export function StatGrid({ children }: { children?: Child }) {
  return <div class="stat-grid">{children}</div>;
}

// One number with its label. `value` arrives pre-formatted, so this component
// never has to decide what an unreadable count should look like -- see
// overview.tsx's count().
//
// `hint` renders as visible text rather than a title attribute. The two hints
// this page actually uses both correct an assumption the number invites (that
// "crash sources" means installs, that a crash total is exact), and a tooltip
// on a div is neither keyboard-reachable nor visible to the reader who most
// needs it.
export function StatCard({
  label,
  value,
  hint,
  badge,
}: {
  label: string;
  value: string;
  hint?: string;
  badge?: Child;
}) {
  return (
    <div class="stat-card">
      <div class="stat-label">{label}</div>
      <div class="stat-value">
        {value}
        {badge}
      </div>
      {hint && <div class="stat-hint">{hint}</div>}
    </div>
  );
}
