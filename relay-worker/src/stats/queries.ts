// The three windows GET /admin offers. Values are seconds, subtracted from
// the current unix second to produce the `since` bound every windowed query
// binds. The key never reaches a query as text: it selects one of these
// integers, which is why parseWindow below is about rendering a coherent page
// and not about injection.
export const WINDOWS = {
  "24h": 86_400,
  "7d": 604_800,
  "30d": 2_592_000,
} as const;

export type WindowKey = keyof typeof WINDOWS;

// Landing on the overview with no explicit window shows a week, which is wide
// enough that a quiet relay still has something on the page and narrow enough
// that a spike from three weeks ago does not read as current.
export const DEFAULT_WINDOW: WindowKey = "7d";

// Same shape of guard as layout.tsx's parsePage, for the same reason: this is
// arbitrary caller-supplied text on a route whose page must render regardless.
//
// hasOwnProperty rather than `raw in WINDOWS`: the `in` operator walks the
// prototype chain, so "toString" and "constructor" would both pass and return
// a WindowKey that WINDOWS[key] cannot resolve to a number.
export function parseWindow(raw: string | undefined): WindowKey {
  if (raw !== undefined && Object.prototype.hasOwnProperty.call(WINDOWS, raw)) {
    return raw as WindowKey;
  }
  return DEFAULT_WINDOW;
}
