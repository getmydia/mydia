// A plugin frame runs in an opaque origin and cannot read the host's stored
// theme, so the host tells it. Plugins only understand the two Mydia names, so
// every host theme (Dracula, Nord, ...) is reduced to its light or dark scheme.
const SCHEME_THEMES = { dark: "mydia-dark", light: "mydia-light" }

export function themeMessage(root) {
  const scheme = root?.getAttribute?.("data-color-scheme")
  const theme = Object.hasOwn(SCHEME_THEMES, scheme) ? SCHEME_THEMES[scheme] : null
  return theme ? { mydia: "theme", theme } : null
}
