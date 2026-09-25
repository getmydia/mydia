// Keeps the poster-grid density in a per-browser cookie.
//
// The server decides: a toggle click goes to the LiveView, and only once it
// accepts the value does it push `grid_density:saved`, which is when the
// cookie is written. MydiaWeb.Plugs.GridDensityCookie reads the cookie on
// the next HTTP request so the first render already has the right columns.
//
// The LiveView session is fixed when the socket connects. After changing
// density on one page, a live navigation to the other mounts with the old
// value, so on mount the hook compares the cookie with the rendered toggle
// and re-sends the stored value when they differ.

export const COOKIE_NAME = "mydia_grid_density";
export const LEVELS = ["comfortable", "compact", "dense"];

const ONE_YEAR_SECONDS = 60 * 60 * 24 * 365;

export function readDensityCookie(cookieString) {
  for (const part of (cookieString || "").split(";")) {
    const [name, ...rest] = part.trim().split("=");

    if (name === COOKIE_NAME) {
      const value = rest.join("=");
      return LEVELS.includes(value) ? value : null;
    }
  }

  return null;
}

export function densityCookie(value) {
  return `${COOKIE_NAME}=${value}; path=/; max-age=${ONE_YEAR_SECONDS}; SameSite=Lax`;
}

const GridDensity = {
  mounted() {
    this.handleEvent("grid_density:saved", ({ density }) => {
      if (LEVELS.includes(density)) document.cookie = densityCookie(density);
    });

    const stored = readDensityCookie(document.cookie);

    if (stored && stored !== this.el.dataset.value) {
      this.pushEvent("set_grid_density", { density: stored });
    }
  },
};

export default GridDensity;
