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
for n in homepage movies tv-shows series calendar; do
  cp "screenshots/$n.png" "site/public/img/$n.png"
done
```

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
    waitFor: "h1, .main-content", // CSS selector to wait for
    follow: 'main a[href^="/tv/"]', // optional: click into a detail page first
    fullPage: false, // Capture full page scroll
  },
];
```

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
