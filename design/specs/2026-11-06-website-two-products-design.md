# Website: Mydia Player and Mydia Server as two products

Date: 2026-11-06
Status: approved design, awaiting implementation plan

## Why

mydia.dev presents Mydia as one self-hosted media manager, with the player as
a section that "connects directly to your server". That is no longer true. The
player now browses and plays from Plex and Jellyfin on its own, and local
folder support is coming. A Plex or Jellyfin user can install the player
without running anything Mydia-side, and the site never tells them so.

The site is redesigned around two products of equal weight:

- **Mydia Player**: the app, on every platform, for the servers you already
  have.
- **Mydia Server**: the public name for today's Phoenix application (library,
  metadata, automated downloads, remote access).

## Decisions

| Question | Decision |
| --- | --- |
| What is "Mydia Server"? | The existing Phoenix app, renamed for the site. The Rust `server/` product is not mentioned. |
| Which product leads? | Neither. The homepage gives both equal space. |
| Structure | Dedicated `/player` and `/server` pages; the homepage introduces both and routes. |
| Sources on the site | Mydia Server, Plex and Jellyfin as supported, without an "experimental" label. Local folders as a "coming soon" tile. Stash is not named on the site (it stays in the docs). |
| Look and stack | Unchanged: Astro, Tailwind, daisyUI, dark theme, existing header and footer styling. Content and pages change, not the brand. |

## Success criteria

- A Plex or Jellyfin user landing on `/` understands within the first screen
  that Mydia Player works with their server and needs nothing installed
  server-side.
- A self-hoster understands what Mydia Server does, how to install it, and
  what running both together adds.
- No existing inbound link breaks (`/download`, `/blog/*`, `/#player`).

## Site map

| Route | Status | Purpose |
| --- | --- | --- |
| `/` | rewritten | Introduces both products and routes visitors to one of them |
| `/player` | new | Mydia Player product page |
| `/server` | new | Mydia Server product page |
| `/download` | title copy only | Player installers; resolver and Pages Functions untouched |
| `/blog`, `/blog/*`, `/rss.xml` | unchanged | |

Header nav becomes: Player, Server, Download, Blog, Docs (external), GitHub
(external). "Home" is dropped; the logo links home.

## Homepage (`/`)

1. **Hero.** A headline covering both products (working copy: "Your media,
   played and managed your way") and one sentence: "A player for every server
   you use, and a server that runs your library." No GitHub button in the
   hero; it stays in the nav.
2. **Two product cards**, side by side on desktop and stacked on mobile, equal
   size.
   - *Mydia Player* (card carries `id="player"` so `/#player` links still
     land here): phone screenshot; bullets "Works with Plex, Jellyfin and
     Mydia Server", "Offline downloads", "On every platform"; buttons
     **Download** (`/download`) and *Learn more* (`/player`).
   - *Mydia Server*: `homepage.png`; bullets "Organizes your library and
     fetches metadata", "Finds and downloads what you're missing", "Remote
     access without port forwarding"; buttons **Get started**
     (`/server#install`) and *Learn more* (`/server`).
3. **Better together strip.** Three short items on what running both adds:
   secure remote streaming from anywhere, offline downloads with transcoding,
   casting. Links to `/server`.
4. **Latest posts.** Existing `LatestPosts` component.

`Features`, `Screenshots`, `Player` and `GetStarted` leave the homepage.

## `/player`

1. **Hero.** "One player for all your media." Subhead: "Plex, Jellyfin, your
   Mydia Server, and soon your own folders, in one app on every screen." CTAs:
   **Download** (`/download`), *See platforms* (`/download#platforms`).
2. **Sources row.** Tiles for Mydia Server, Plex, Jellyfin, and a dimmed
   "Local folders, coming soon" tile. A line beneath: sign in to the servers
   you already have; nothing to install on them. Links to the docs page
   `using/how-to/connect-other-servers/`.
3. **Features grid**, six cards: every platform (phone, tablet, TV, desktop,
   web); offline downloads; cast to Chromecast and DLNA; Plex Home profiles;
   native hardware-accelerated playback; continue watching across servers.
   Each claim is checked against the player code during implementation; a
   claim that does not hold is replaced, not softened.
4. **Screenshots.** Phone and desktop mockups, retaken against the demo
   library. There is no multi-source screenshot: the web build, which the
   capture script drives, hides third-party sources entirely
   (`add_source_screen.dart`). The sources row above carries that message as
   an illustration instead.
5. **Pick your look.** `ThemeShowcase` with the player presets Projection
   Booth, OLED Black and Slate.
6. **Platforms strip.** The existing platform chips, linking to `/download`.
7. **Cross-sell.** "Run your own library? Pair it with Mydia Server for remote
   streaming without port forwarding." Links to `/server`.

## `/server`

1. **Hero.** "Your library, on autopilot." Subhead: "A self-hosted server that
   organizes your movies and TV, finds what's missing, and streams it to Mydia
   Player anywhere." CTAs: **Get started** (`#install`), *Docs* (external).
2. **Features grid**, six cards drawn from the README in plain language:
   library and metadata; automated downloads with quality profiles and
   upgrades; works with your download clients and indexers (naming
   qBittorrent, SABnzbd, Prowlarr, debrid providers); multi-user with requests
   and SSO; remote access without port forwarding; configure in the UI or in
   files.
3. **Screenshots.** The existing `Screenshots` carousel (dashboard, movies,
   TV, calendar), retaken against the demo library.
4. **Themes.** `ThemeShowcase` headed "14 themes, light and dark, or follow
   your system", with six curated themes: Mydia Dark, Mydia Light, Nord,
   Dracula, Catppuccin Mocha, Sunset.
5. **Install** (`id="install"`). The README's Docker Compose snippet with a
   copy button, three numbered steps (generate secrets, create the file,
   `docker compose up -d`), then "Full guide" to the docs.
6. **Cross-sell.** "Watch it with Mydia Player." Links to `/player`.

## Components and data

- `Features.astro` becomes props-driven (`title`, `subtitle`, `items`) and is
  used by both product pages. Icons stay inline SVG paths, as today.
- `Player.astro` is split: its platform chips become a `Platforms` component
  used on `/player` (and nowhere else); its mockups move into the `/player`
  screenshots section.
- `GetStarted.astro` is replaced by an `Install` component on `/server`.
- New components: `ProductCard` (homepage cards), `Sources` (player sources
  row), `CrossSell` (the one-line banner at the foot of each product page).
- `site/src/data/` holds the content that has a second copy or a future
  flip: `sources.ts` (the source tiles, each with `status: 'available' |
  'soon'`, so shipping local folders is a one-line change) and
  `compose.ts` (the Docker Compose snippet).
- Each page sets its own `<title>` and meta description through `Base`
  props, e.g. "Mydia Player: one app for Plex, Jellyfin and Mydia Server".

## Copy rules

- Written for end users. No implementation terms: no iroh, QUIC, LiveView,
  GraphQL, NIF.
- "Mydia Player" and "Mydia Server" always in full.
- No em dashes.
- Screenshots show invented titles only.
- Stash is not named on the site.

## Changes outside `site/`

- `README.md`: drop "This is experimental" from the Plex/Jellyfin sentence,
  and name the Phoenix app "Mydia Server" where the README introduces it.
- Docs links across the site move from `getmydia.github.io/mydia/latest/` to
  `docs.mydia.dev/latest/`, the URL the README already uses.
- The `mydia.demo_seed` mix task and the `assets/screenshots.js` changes
  (see below), and the retaken images in `screenshots/`.
- Not in scope: the docs site, the app's own UI, and the Rust `server/`.

## Verification

- `npm run build` in `site/`, and the existing vitest suite.
- A vitest test asserting `compose.ts` matches the Compose block in
  `README.md`, so the two cannot drift.
- A vitest test asserting every server theme id in `themes.ts` exists in
  `Mydia.Accounts.Themes` (read from `lib/mydia/accounts/themes.ex`), and
  every player preset id exists in `ThemePreset`, so a renamed theme fails
  the build instead of shipping a broken swatch.
- An ExUnit test for `mydia.demo_seed`: it seeds an empty database, refuses a
  non-empty one, and every seeded title is in its own invented list.
- A link check over the built `dist/` covering internal routes and anchors
  (`/#player`, `/server#install`, `/download#platforms`).
- Playwright screenshots of `/`, `/player`, `/server` and `/download` at
  mobile and desktop widths, reviewed by the maintainer before the PR.

## Screenshots and theme showcases

Every screenshot on the site is retaken, reproducibly, against an invented
library.

### Demo library: `mix mydia.demo_seed`

- About 20 invented movies and 8 invented shows, with seasons, episodes,
  watch progress (so Continue Watching is populated) and upcoming calendar
  entries.
- Runs against a fresh dev database and refuses to run on one that already
  holds media.
- Poster and backdrop art is generated: SVG templates (title, gradient,
  simple shapes) rendered with `rsvg-convert`. No real artwork, no
  metadata-relay calls.
- Artwork is served by Phoenix itself. `Mydia.Metadata.ImageUrl` passes any
  `http…` value through untouched, so the seed stores
  `MydiaWeb.Endpoint.url() <> "/images/demo/<file>.png"` as `poster_path` and
  `backdrop_path`, and writes the PNGs to `priv/static/images/demo/`
  (gitignored; `images` is already a static path). Same origin, so the
  Flutter web build can load them without CORS.
- Media files are database rows only, under a demo library path; nothing is
  written to a media folder.

### Capture: `assets/screenshots.js`, extended

- Server pages (dashboard, movies, TV, calendar) as today, against the demo
  seed.
- **Server theme set:** the dashboard in the six curated themes. The
  script's `setTheme` calls `window.mydiaTheme`, which no longer exists, so
  every shot silently used the user's saved theme. It is replaced by setting
  `data-theme`, `data-color-scheme` and the background colour on `<html>`
  after each navigation; LiveView never patches `<html>`, so the theme holds
  for the shot. No user setting is written.
- **Player theme set:** home at desktop and phone sizes in Projection Booth,
  OLED Black and Slate. Before boot the script sets localStorage
  `mydia_auth_theme_preset` to the enum name (`projectionBooth`,
  `oledBlack`, `slate`), which is where the web build's `SettingsService`
  reads it. No test hooks are added to the app. The macOS preset exists only
  in the native Mac app and is not captured.
- Output goes to `screenshots/` (README) and to
  `site/src/assets/screenshots/`, where Astro's image pipeline emits sized
  WebP at build time, so the site does not serve 1920px PNGs.

### `ThemeShowcase.astro`

- One large screenshot with a row of labeled swatches beneath; clicking a
  swatch swaps the image. Swatch colour is the theme's base colour.
- A small inline script. Non-selected images load lazily; without JS the
  default theme's image still shows.
- Props: a heading and a list of `{ id, label, swatch, image }`.
- Theme lists live in `site/src/data/themes.ts`.
