import { describe, it, expect } from "vitest";
import { Tabs, DataTable, Badge, PostButton, Pager, StatGrid, StatCard, FLOOR_TITLE } from "../../src/dashboards/ui";
import { css } from "../../src/dashboards/styles";

// A component that renders nothing returns null, and null has no toString.
// Verified against hono/jsx 4.13.7: `Pager({ href: null })` is literally
// null, so calling .toString() on it throws a TypeError. As a *child* of
// another element null is dropped cleanly, which is why this only matters
// when a component is rendered directly in a test.
function render(node: unknown): string {
  return node == null ? "" : (node as { toString(): string }).toString();
}

describe("Tabs", () => {
  it("marks only the active link with aria-current", () => {
    const html = render(
      Tabs({
        links: [
          { href: "/admin/errors", label: "all", active: false },
          { href: "/admin/errors?status=resolved", label: "resolved", active: true },
        ],
      }),
    );
    expect(html).toContain('href="/admin/errors?status=resolved" aria-current="page"');
    expect(html.match(/aria-current/g)).toHaveLength(1);
  });

  it("escapes a hostile label", () => {
    const html = render(Tabs({ links: [{ href: "/x", label: "<script>", active: false }] }));
    expect(html).not.toContain("<script>");
    expect(html).toContain("&lt;script&gt;");
  });
});

describe("DataTable", () => {
  it("renders headers and wraps the table for horizontal overflow", () => {
    const html = render(DataTable({ headers: ["Kind", "Message"], children: "ROWS" }));
    expect(html).toContain('class="table-wrap"');
    expect(html).toContain("<th>Kind</th>");
    expect(html).toContain("<th>Message</th>");
    expect(html).toContain("ROWS");
  });

  it("emits no key attribute for mapped headers", () => {
    const html = render(DataTable({ headers: ["A", "B"], children: "" }));
    expect(html).not.toContain("key=");
  });
});

describe("Badge", () => {
  it("keeps the explanatory title and escapes both inputs", () => {
    const html = render(Badge({ label: "throttled", title: 'why "this" is a floor' }));
    expect(html).toContain('class="badge"');
    expect(html).toContain("throttled");
    expect(html).toContain("&quot;this&quot;");
  });
});

describe("PostButton", () => {
  it("posts to the action with the given hidden fields", () => {
    const html = render(
      PostButton({ action: "/admin/feedback/abc/state", label: "archive", fields: { state: "archived" } }),
    );
    expect(html).toContain('method="post"');
    expect(html).toContain('action="/admin/feedback/abc/state"');
    expect(html).toContain('<input type="hidden" name="state" value="archived"');
    expect(html).toContain(">archive</button>");
  });

  it("renders no hidden inputs when no fields are given", () => {
    const html = render(PostButton({ action: "/a", label: "Resolve" }));
    expect(html).not.toContain('type="hidden"');
  });
});

describe("Pager", () => {
  it("renders nothing when there is no next page", () => {
    expect(render(Pager({ href: null }))).toBe("");
  });

  it("renders a next link when there is one", () => {
    const html = render(Pager({ href: "/admin/errors?page=1" }));
    expect(html).toContain('href="/admin/errors?page=1"');
    expect(html).toContain("Next");
  });
});

describe("StatCard", () => {
  it("renders its label and value", () => {
    const html = render(StatCard({ label: "Crashes", value: "42" }));
    expect(html).toContain("Crashes");
    expect(html).toContain("42");
    expect(html).toContain('class="stat-card"');
  });

  // A hint is a visible line rather than a title tooltip: the reader has to
  // see that "crash sources" is IP-derived without hovering a div, which is
  // not reachable by keyboard anyway.
  it("renders a hint as visible text when given one", () => {
    const html = render(
      StatCard({ label: "Crash sources", value: "8", hint: "IP-derived" }),
    );
    expect(html).toContain('class="stat-hint"');
    expect(html).toContain("IP-derived");
  });

  it("emits no hint element when no hint is given", () => {
    const html = render(StatCard({ label: "Crashes", value: "42" }));
    expect(html).not.toContain("stat-hint");
  });

  it("escapes a label and value it is handed", () => {
    const html = render(
      StatCard({ label: "<script>alert(1)</script>", value: "<b>x</b>" }),
    );
    expect(html).not.toContain("<script>alert(1)</script>");
    expect(html).toContain("&lt;script&gt;");
    expect(html).not.toContain("<b>x</b>");
  });

  it("renders a badge alongside the value", () => {
    const html = render(
      StatCard({
        label: "Crashes",
        value: "42",
        badge: Badge({ label: "throttled", title: "why" }),
      }),
    );
    expect(html).toContain("throttled");
  });
});

describe("StatGrid", () => {
  it("wraps its children in the grid container", () => {
    const html = render(StatGrid({ children: "CARDS-MARKER" }));
    expect(html).toContain('class="stat-grid"');
    expect(html).toContain("CARDS-MARKER");
  });
});

describe("stat card styles", () => {
  it("defines every class the components emit", () => {
    for (const selector of [
      ".stat-grid",
      ".stat-card",
      ".stat-label",
      ".stat-value",
      ".stat-hint",
    ]) {
      expect(css).toContain(selector);
    }
  });
});

describe("FLOOR_TITLE", () => {
  // The badge itself only says "throttled". This constant is the entire
  // explanation of what that means, so a version that just restates the label
  // would be useless to the maintainer reading it.
  it("explains the mechanism, not just the label", () => {
    expect(FLOOR_TITLE).toContain("hourly bucket");
    expect(FLOOR_TITLE).toContain("floor");
    expect(FLOOR_TITLE.length).toBeGreaterThan(80);
  });
});
