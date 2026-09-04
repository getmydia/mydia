# 📸 Screenshot Tool

Automated screenshot capture for Mydia using Playwright. These are the images in
the README, on [mydia.dev](https://mydia.dev) and in the docs landing page, so a
capture run is only useful against a library that looks like a real one.

## Quick Start

```bash
# Start the app and note the port devenv derived for this worktree
./dev up -d
./dev ps

# From the repo root
BASE_URL=http://localhost:<port> ./take-screenshots
```

Screenshots are written to `screenshots/` in the project root. The site serves
its own copies from `site/public/img/`, so copy the updated files across:

```bash
for n in homepage movies tv-shows series calendar \
         player-desktop player-home player-shows; do
  cp "screenshots/$n.png" "site/public/img/$n.png"
done
```

`homepage-light.png` is deliberately not copied: mydia.dev is a dark-only site,
and the light dashboard exists only so the README can swap on the reader's own
colour scheme.

## What gets captured

| File | What it is |
| --- | --- |
| `homepage.png` | Dashboard, dark theme. README hero and site featured image. |
| `homepage-light.png` | The same page in the light theme, for the README `<picture>` swap. |
| `movies.png`, `tv-shows.png` | Library grids, dark. |
| `series.png` | Series detail, reached by clicking the first card on `/tv`. |
| `calendar.png` | Release calendar, dark. |
| `player-desktop.png` | Mydia Player at 1920 wide. |
| `player-home.png`, `player-shows.png` | Mydia Player at phone width, for the site's phone mockups. |

The player shots come from the Flutter **web** build the server hosts at
`/player`, which is the same app as the native builds, so they stay current
without a device or a simulator. Set `SKIP_PLAYER=1` to skip them; they cost
about 40 seconds of canvaskit start-up.

## Configuration

Environment variables (optional):

```bash
BASE_URL=http://localhost:4000    # App URL, per-worktree in devenv
OUTPUT_DIR=../screenshots          # Output directory
USERNAME=admin                     # Login username
PASSWORD=adminpass                 # Login password (as created by seeds.exs)
CHROME_PATH=/path/to/chromium      # Browser override, required on NixOS
```

`./take-screenshots` fills in `CHROME_PATH` from the system Chromium when it
finds one, because Playwright's bundled build cannot start on NixOS.

## Preparing a library worth photographing

An empty library screenshots as a wall of empty states. Before capturing:

1. `./dev mix run priv/repo/seeds.exs` creates `admin` / `adminpass`.
2. Add titles through **Discover** so posters, ratings and episode lists come
   from the real metadata-relay round trip.
3. Attach files, otherwise every item renders as missing and the calendar is a
   sea of red. Sparse files are enough: the UI reads size, resolution and codec
   from `media_files`, and a sparse file reports a realistic size while costing
   nothing on disk.
4. Point the library paths at neutral locations (`/media/movies`, `/media/tv`)
   so no personal path ends up on the series page.

## Customizing Screenshots

Edit `assets/screenshots.js` to add or modify pages:

```javascript
const screenshots = [
  {
    name: "my-page",
    path: "/my-page",
    description: "My custom page",
    waitFor: "h1, h2, main", // CSS selector to wait for (matched as attached)
    follow: 'main a[href^="/media/"]', // optional: click into a detail page first
    theme: "DARK", // DARK, LIGHT or SYSTEM
    fullPage: false, // Capture full page scroll
  },
];
```

Two traps worth knowing if you add a page:

- `waitFor` is matched with `state: "attached"`, not Playwright's default
  `"visible"`. A comma-separated selector resolves to the **first** match, and
  the layout's own `<h1>Mydia</h1>` is present but hidden, so the default
  timed out on every page and left each shot racing the settle timer.
- Library cards link to `/media/:id`, not `/movies/:id` or `/tv/:id`. A
  `follow` selector written against the pretty URL matches nothing. That used
  to screenshot the listing a second time under the detail page's name, so a
  `follow` that finds nothing now **fails the run**, and the click is followed
  by a wait on `#main-column`, which only the detail page renders. Override
  that with `follow_wait` if you add a shot that lands somewhere else.

## Viewport Size

Default: 1920x1080. Change in `config.viewport` in `screenshots.js`.

## Compressing

The raw captures are several megabytes each. Shrink them before committing:

```bash
nix shell nixpkgs#pngquant nixpkgs#oxipng -c sh -c '
  for f in screenshots/*.png; do
    pngquant --quality=70-92 --speed 1 --force --output "$f" "$f"
    oxipng -o 4 --strip safe -q "$f"
  done'
```
