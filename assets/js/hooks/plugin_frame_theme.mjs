// A plugin frame runs in an opaque origin and cannot read the host's stored
// theme, so the host tells it. Only the host's own themes are ever sent.
export const FRAME_THEMES = ["mydia-dark", "mydia-light"]

export function themeMessage(root) {
  const theme = root?.getAttribute?.("data-theme")
  return FRAME_THEMES.includes(theme) ? { mydia: "theme", theme } : null
}
