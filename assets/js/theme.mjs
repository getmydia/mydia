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

export function applySelection(root, selection, prefersDark, storage) {
  root.setAttribute("data-theme-mode", selection.mode);
  root.setAttribute("data-light-theme", selection.light);
  root.setAttribute("data-dark-theme", selection.dark);
  root.setAttribute("data-light-base", selection.lightBase);
  root.setAttribute("data-dark-base", selection.darkBase);

  const id = resolveThemeId(selection, prefersDark);
  root.setAttribute("data-theme", id);
  root.style.backgroundColor =
    id === selection.dark ? selection.darkBase : selection.lightBase;

  // The mirror only serves pages with no signed-in user (login, setup).
  try {
    storage.setItem(MIRROR_KEY, JSON.stringify(selection));
  } catch (_e) {
    // Private mode or a full quota: the server copy is what matters.
  }
}
