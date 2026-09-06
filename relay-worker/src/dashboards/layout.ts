// Shared chrome for the maintainer dashboards (errors, feedback). This
// dashboard is UNAUTHENTICATED until Task 15 puts Cloudflare Access in front
// of it -- do not add ad-hoc auth here, but also do not add anything (an
// inline API key, a bypassable query param, etc.) that would make it harder
// for Task 15 to gate this route entirely at the edge.

// Every value rendered into one of these pages can originate from an
// unauthenticated remote install (POST /crashes/report, POST /feedback are
// both open). escapeHtml is the one and only sanctioned way to interpolate
// dynamic text into a template string here -- never interpolate a
// crash/feedback-derived value without it, including values that "look safe"
// like a hex fingerprint or an integer count.
export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.5 ui-sans-serif, system-ui, sans-serif; margin: 0; padding: 2rem; }
  h1 { font-size: 1.25rem; }
  nav a { margin-right: 1rem; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: .5rem .75rem; border-bottom: 1px solid #8883; vertical-align: top; }
  th { font-weight: 600; }
  pre { overflow-x: auto; background: #8881; padding: .75rem; border-radius: .375rem; }
  .muted { opacity: .65; }
  .floor { white-space: nowrap; }
  .floor .badge {
    display: inline-block; margin-left: .35rem; padding: .05rem .4rem;
    border-radius: .25rem; font-size: .75rem; background: #f59e0b3d; color: inherit;
  }
  form { display: inline; }
  button { font: inherit; padding: .25rem .6rem; cursor: pointer; }
</style>
</head>
<body>
<nav><a href="/errors">Errors</a><a href="/feedback">Feedback</a></nav>
<h1>${escapeHtml(title)}</h1>
${body}
</body>
</html>`;
}
