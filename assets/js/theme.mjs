// Applies a theme selection to <html>. The server renders the same
// attributes on first load (MydiaWeb.Layouts.theme_html_attrs/1); this runs
// when a LiveView pushes `theme_changed`. The inline script in
// root.html.heex repeats resolveThemeId because it must run before any
// bundle loads; keep the two in step.

export const MIRROR_KEY = "mydia-theme";

export function resolveThemeId(selection, prefersDark) {
  if (selection.mode === "light") return selection.light;
  if (selection.mode === "dark") return selection.dark;
  return prefersDark ? selection.dark : selection.light;
}

export function fromPayload(detail) {
  return {
    mode: detail.mode,
    light: detail.light_theme,
    dark: detail.dark_theme,
    lightBase: detail.light_base,
    darkBase: detail.dark_base,
  };
}

// Mirrors MydiaWeb.Layouts.theme_color_meta/1: one meta with the active base
// for fixed modes, a light/dark media pair for system mode.
export function updateThemeColorMetas(doc, selection) {
  for (const meta of doc.querySelectorAll('meta[name="theme-color"]')) {
    meta.remove();
  }
  const specs =
    selection.mode === "system"
      ? [
          ["(prefers-color-scheme: light)", selection.lightBase],
          ["(prefers-color-scheme: dark)", selection.darkBase],
        ]
      : [
          [
            null,
            selection.mode === "dark" ? selection.darkBase : selection.lightBase,
          ],
        ];
  for (const [media, content] of specs) {
    const meta = doc.createElement("meta");
    meta.setAttribute("name", "theme-color");
    if (media) meta.setAttribute("media", media);
    meta.setAttribute("content", content);
    doc.head.append(meta);
  }
}

export function applySelection(root, selection, prefersDark, storage, doc) {
  root.setAttribute("data-theme-mode", selection.mode);
  root.setAttribute("data-light-theme", selection.light);
  root.setAttribute("data-dark-theme", selection.dark);
  root.setAttribute("data-light-base", selection.lightBase);
  root.setAttribute("data-dark-base", selection.darkBase);

  const id = resolveThemeId(selection, prefersDark);
  root.setAttribute("data-theme", id);
  root.setAttribute(
    "data-color-scheme",
    id === selection.dark ? "dark" : "light",
  );
  root.style.backgroundColor =
    id === selection.dark ? selection.darkBase : selection.lightBase;

  if (doc) updateThemeColorMetas(doc, selection);

  // The mirror only serves pages with no signed-in user (login, setup).
  try {
    storage.setItem(MIRROR_KEY, JSON.stringify(selection));
  } catch (_e) {
    // Private mode or a full quota: the server copy is what matters.
  }
}
