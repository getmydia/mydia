import { describe, it, expect } from "vitest";
import { page, Layout } from "../../src/dashboards/layout";
import { css } from "../../src/dashboards/styles";

// A component that renders nothing returns null, and null has no toString.
// Verified against hono/jsx 4.13.7: `Pager({ href: null })` is literally
// null, so calling .toString() on it throws a TypeError. As a *child* of
// another element null is dropped cleanly, which is why this only matters
// when a component is rendered directly in a test.
function render(node: unknown): string {
  return node == null ? "" : (node as { toString(): string }).toString();
}

describe("page shell", () => {
  it("emits a doctype so browsers do not fall into quirks mode", () => {
    const html = render(page("Errors", "hi"));
    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain('<html lang="en">');
  });

  it("escapes the title everywhere it appears", () => {
    const html = render(page('<script>alert(1)</script>', "body"));
    expect(html).not.toContain("<script>alert(1)</script>");
    expect(html).toContain("&lt;script&gt;");
  });

  it("passes the stylesheet through raw so CSS syntax survives", () => {
    const html = render(page("Errors", "body"));
    expect(html).toContain("--accent:");
    expect(html).not.toContain("&gt; td");
    expect(html).toContain("color-scheme: light dark");
  });

  it("renders both nav links", () => {
    const html = render(page("Errors", "body"));
    expect(html).toContain('href="/admin/errors"');
    expect(html).toContain('href="/admin/feedback"');
  });

  it("renders children inside main", () => {
    const html = render(Layout({ title: "T", children: "BODY-MARKER" }));
    expect(html).toContain("BODY-MARKER");
  });

  it("defines every token the components rely on", () => {
    for (const token of [
      "--bg", "--surface", "--fg", "--muted", "--line",
      "--accent", "--warn-fg", "--warn-bg", "--radius",
    ]) {
      expect(css).toContain(`${token}:`);
    }
  });
});
