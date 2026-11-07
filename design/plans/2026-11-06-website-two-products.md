# Website: two products, demo screenshots, theme showcases. Implementation Plan

> **Historical record.** This plan describes the original approach. The demo seed changed during implementation: it now reads a local, git-ignored list of TMDB ids and fetches metadata and artwork through the metadata relay, rather than generating invented artwork. See the spec, `design/specs/2026-11-06-website-two-products-design.md`, for the current design.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild mydia.dev around Mydia Player and Mydia Server as equal products, with every screenshot retaken against an invented demo library and theme showcases for both products.

**Architecture:** An Elixir mix task seeds an invented library (DB rows plus generated PNG artwork served by Phoenix). The existing Playwright capture script is extended to take per-theme shots and write them into the Astro site's `src/assets/`. The Astro site gains `/player` and `/server` pages built from small props-driven components whose content lives in typed `src/data/` modules guarded by vitest parity tests.

**Tech Stack:** Elixir/Ecto (mix task), librsvg `rsvg-convert` (in devenv), Node Playwright (`assets/screenshots.js`), Astro 7 + Tailwind 4 + daisyUI 5, `astro:assets`, vitest.

**Spec:** `design/specs/2026-11-06-website-two-products-design.md`

## Global Constraints

- "Mydia Server" = the Phoenix app. The Rust `server/` is never mentioned on the site.
- "Mydia Player" and "Mydia Server" always written in full.
- Site copy: end-user language; no iroh, QUIC, LiveView, GraphQL, NIF. No em dashes anywhere (copy, code comments, commit messages).
- Stash is not named on the site.
- Only invented movie/show titles, in seed data, tests and screenshots.
- Visual stack unchanged: Astro, Tailwind, daisyUI, dark theme, existing header/footer styling.
- Docs links use `https://docs.mydia.dev/latest/`, never `getmydia.github.io/mydia/latest/`.
- Curated server themes, in this order: `mydia-dark`, `mydia-light`, `nord`, `dracula`, `mocha`, `sunset`.
- Player presets shown, in this order: `projectionBooth`, `oledBlack`, `slate`.
- Inbound links that must keep working: `/download`, `/download#platforms`, `/blog/*`, `/rss.xml`, `/#player`.
- Commits run inside the devenv environment (`direnv exec . git commit -F <msgfile>`); verify each with `git show --stat`.

## Review Focus

1. **Seed run twice, or on a real library.** A maintainer re-runs `mydia.demo_seed` on a DB that already has the demo (or their own) media. Expected: it refuses with a clear message and writes nothing. Pinned in Task 1 (`refuses a database that already holds media`).
2. **`rsvg-convert` missing** (task run outside devenv). Expected: the task stops before touching the DB with a message naming librsvg/devenv, not a half-seeded library with broken images. Pinned in Task 1 (`fails before writing when the renderer is missing`).
3. **A theme renamed in the app or player.** Expected: the site build's tests fail naming the id, not a swatch that silently shows the wrong image. Pinned in Task 2.
4. **Visitor without JavaScript** on `/server` or `/player`. Expected: the default theme's screenshot is visible and swatches are inert, not an empty frame. Pinned in Task 3 (`renders the first theme's image without JS`).
5. **A TV episode file seeded with `media_item_id` set.** The media README says TV `media_files` carry `episode_id` and a NULL `media_item_id`; the changeset refuses the other shape. Expected: seeded shows appear in the TV library and player like scanned ones. Pinned in Task 1 (`episode files hang off episodes`).

---

### Task 1: Demo library seed

**Files:**
- Create: `lib/mydia/demo/library.ex` (data + `seed/1`)
- Create: `lib/mydia/demo/artwork.ex` (SVG templates + rendering)
- Create: `lib/mix/tasks/mydia.demo_seed.ex`
- Modify: `.gitignore` (add `/priv/static/images/demo/`)
- Test: `test/mydia/demo/library_test.exs`

**Interfaces:**
- Produces: `Mydia.Demo.Library.seed(opts :: keyword()) :: {:ok, %{movies: non_neg_integer(), shows: non_neg_integer(), episodes: non_neg_integer()}} | {:error, :not_empty | {:renderer_missing, String.t()}}`. Options: `:art_dir` (default `Application.app_dir(:mydia, "priv/static/images/demo")`), `:base_url` (default `MydiaWeb.Endpoint.url()`), `:renderer` (default `"rsvg-convert"`), `:user` (the admin `%User{}` that gets watch progress; default: first admin).
- Produces: `Mydia.Demo.Library.titles() :: [String.t()]`, every movie and show title the seed can write.
- Produces: `Mydia.Demo.Artwork.render(title :: String.t(), kind :: :poster | :backdrop, dir :: Path.t(), renderer :: String.t()) :: {:ok, filename :: String.t()} | {:error, term()}`. Poster 500x750, backdrop 1280x720.
- Produces: `mix mydia.demo_seed`, run as `./dev mix mydia.demo_seed`.

- [ ] **Step 1: Write the failing tests** in `test/mydia/demo/library_test.exs` (`use Mydia.DataCase`, `async: false`; `art_dir` from `@tag :tmp_dir`; a fake renderer is a shell script in `tmp_dir` that writes a 1x1 PNG to the `-o` path, so the test does not need librsvg):
  - `seeds an empty database`: `{:ok, %{movies: m, shows: s, episodes: e}}` with `m >= 18`, `s >= 6`, `e > 0`; every `MediaItem.title` is in `Library.titles()`; every movie's `metadata.poster_path` starts with `base_url <> "/images/demo/"` and the file exists in `art_dir`.
  - `refuses a database that already holds media`: insert one media item via the factory; `seed/1` returns `{:error, :not_empty}` and the media item count is still 1 and `art_dir` is empty.
  - `fails before writing when the renderer is missing`: `renderer: "/nonexistent/rsvg-convert"` returns `{:error, {:renderer_missing, _}}`, zero media items.
  - `episode files hang off episodes`: every `MediaFile` with an `episode_id` has `media_item_id == nil`; every movie has exactly one `MediaFile` with `media_item_id` set.
  - `populates Continue Watching and the calendar`: at least 3 `Mydia.Playback.Progress` rows for the user with `0 < position_seconds < duration_seconds`, and at least 3 episodes with `air_date` within the next 14 days.
  - `titles are unique and fit a poster`: `Library.titles()` has no duplicates and every title is at most 40 characters. Whether a title is invented is checked by a person reviewing the list in the PR, not by a test.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./dev mix test test/mydia/demo/library_test.exs`
Expected: FAIL, `Mydia.Demo.Library` is undefined.

- [ ] **Step 3: Implement `Mydia.Demo.Artwork.render/4`.** SVG via EEx-free string interpolation: a two-stop linear gradient whose hues derive from `:erlang.phash2(title)`, two or three translucent circles/rects, and the title in a large sans font (XML-escape it). Write `<slug>-<kind>.svg` to a temp file and run `System.cmd(renderer, ["-w", w, "-h", h, "-o", png, svg])`. Check `System.find_executable/1` (or `File.exists?/1` for absolute paths) once in `seed/1` before any write.

- [ ] **Step 4: Implement `Mydia.Demo.Library.seed/1`.** Order: renderer check, emptiness check (`Repo.exists?(MediaItem)`), then everything inside one `Repo.transaction`. Data, held as module attributes:
  - 20 invented movies: `%{title, year, overview, genres, runtime}`.
  - 8 invented shows: `%{title, year, overview, genres, seasons: [episode_count, ...]}` (1 to 3 seasons, 6 to 10 episodes each).
  - Media items go through `Mydia.Media.create_media_item(Scope.system(), attrs, skip_episode_refresh: true)` with `metadata` holding `provider: :tmdb`, `media_type`, `title`, `overview`, `genres`, `poster_path`, `backdrop_path`, `vote_average`, and `tmdb_id` set to `900_000 + index` so nothing collides with a real lookup.
  - Episodes go through `Mydia.Media.Episodes.create_episode/1`. Air dates are spread backwards from today, except that each show's last 1 to 2 episodes fall within the next 14 days.
  - One library path per type via `Mydia.Settings.LibraryPaths.create_library_path/1`, at `/demo/movies` and `/demo/tv`. Media files go through `Mydia.Library.MediaFiles.create_media_file/1`, with `size`, `resolution: "1080p"`, `codec: "h264"` and `audio_codec: "aac"`, and a path under the library path. TV files set only `episode_id`. Episodes airing in the future get no file.
  - Progress rows via `Mydia.Playback.save_progress/4` for 2 movies and the next unwatched episode of 2 shows. Earlier episodes of those shows are saved as fully watched.
  - Artwork is rendered for every item before the transaction, so a render failure writes no rows.

- [ ] **Step 5: Implement the mix task.** `@shortdoc "Seed an invented demo library for screenshots"`, `Mix.Task.run("app.start")` as `mydia.user` does, print counts or the error, `exit({:shutdown, 1})` on error. Add `/priv/static/images/demo/` to `.gitignore`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `./dev mix test test/mydia/demo/library_test.exs`
Expected: PASS (6 tests).

Execution order: Task 1, Task 2, Task 5 (capture), Task 3, Task 4, Task 6, Task 7. Task 5 needs only Task 1's seed and Task 2's ids. Running it before the components means Tasks 3 and 4 work against real images in `site/src/assets/screenshots/`.

- [ ] **Step 7: Smoke-test against a fresh dev DB.** Use a scratch database, never the maintainer's, with `./dev mix ecto.reset`, which this worktree's devenv isolates per worktree. Then run `./dev mix mydia.demo_seed`, `./dev up -d`, and open `/movies`, `/tv`, `/calendar` and `/player`.
Expected: posters render on all four, and the player home shows Continue Watching.

- [ ] **Step 8: Commit**

```bash
git add lib/mydia/demo lib/mix/tasks/mydia.demo_seed.ex test/mydia/demo .gitignore
git commit -F <msgfile>   # "feat(dev): seed an invented demo library for screenshots"
```

### Task 2: Site data modules and parity tests

**Files:**
- Create: `site/src/data/themes.ts`, `site/src/data/sources.ts`, `site/src/data/compose.ts`
- Test: `site/src/data/themes.test.ts`, `site/src/data/compose.test.ts`

**Interfaces:**
- Produces (`themes.ts`):
  ```ts
  export interface ThemeShot { id: string; label: string; swatch: string; image: string }
  export const serverThemes: ThemeShot[]   // 6 entries, Global Constraints order
  export const playerThemes: ThemeShot[]   // 3 entries, Global Constraints order
  ```
  `image` is a filename in `site/src/assets/screenshots/`: `server-theme-<id>.png` and `player-theme-<id>.png`. `swatch` is the theme's base colour. For server themes it's the `base:` value in `lib/mydia/accounts/themes.ex`, e.g. `mydia-dark` is `#0f172a` and `mocha` is `#1e1e2e`. For player presets it's the scaffold background in `player/lib/core/theme/palette.dart`.
- Produces (`sources.ts`): `export interface SourceTile { id: 'mydia' | 'plex' | 'jellyfin' | 'folders'; name: string; status: 'available' | 'soon' }` and `export const sources: SourceTile[]`. The `folders` tile has `status: 'soon'` and name `Local folders`.
- Produces (`compose.ts`): `export const composeYaml: string`, the README's Compose block verbatim.

- [ ] **Step 1: Write the failing tests**
  - `themes.test.ts`, `every server theme id exists in Mydia.Accounts.Themes`: read `../../../lib/mydia/accounts/themes.ex` with `fs`, extract `id: "(...)"` matches, and assert each `serverThemes[i].id` is in the set and its `swatch` equals that theme's `base:` value.
  - `themes.test.ts`, `every player preset exists in ThemePreset`: read `../../../player/lib/core/theme/theme_preset.dart`, extract the enum value names between `enum ThemePreset {` and the first `;`, and assert each `playerThemes[i].id` is among them and is not `macos`.
  - `compose.test.ts`, `matches the README`: read `../../../README.md`, take the first fenced `yaml` block under `## Quick Start`, and assert it equals `composeYaml` after trimming.

- [ ] **Step 2: Run to verify failure**

Run: `cd site && npm test`
Expected: FAIL, modules not found.

- [ ] **Step 3: Write the three data modules** with the values above.

- [ ] **Step 4: Run to verify pass**

Run: `cd site && npm test`
Expected: PASS, including the existing `release-assets` and `install-script` tests.

- [ ] **Step 5: Commit**: "feat(site): theme, source and compose data with parity tests"

### Task 3: Site components

**Files:**
- Modify: `site/src/components/Features.astro` (props: `title: string`, `subtitle: string`, `items: { title: string; description: string; icon: string }[]`; `iconPaths` stays in the component)
- Create: `site/src/components/ProductCard.astro`, `Sources.astro`, `CrossSell.astro`, `ThemeShowcase.astro`, `Install.astro`, `Platforms.astro`
- Delete: `site/src/components/Player.astro`, `site/src/components/GetStarted.astro`
- Modify: `site/src/components/Screenshots.astro` (images from `src/assets/screenshots/` via `astro:assets`)
- Test: `site/src/components/theme-showcase.test.ts`

**Interfaces:**
- Consumes: `ThemeShot`, `serverThemes`, `playerThemes`, `sources`, `composeYaml` (Task 2).
- Produces the following component props:
  - `ProductCard { id?: string; name: string; image: ImageMetadata; imageAlt: string; bullets: string[]; primary: { label: string; href: string }; secondary: { label: string; href: string } }`
  - `Sources {}`, which reads `sources`
  - `CrossSell { text: string; href: string; label: string }`
  - `ThemeShowcase { id: string; heading: string; subheading?: string; themes: ThemeShot[]; aspect: 'desktop' | 'phone' }`
  - `Install {}`, which reads `composeYaml` and renders `id="install"`
  - `Platforms {}`: the platform chips array moves here from `Player.astro` unchanged.
- Images: `ThemeShowcase` resolves `ThemeShot.image` with `import.meta.glob('../assets/screenshots/*.png', { eager: true })` and `getImage({ src, format: 'webp', width: 1600 })` (phone: `width: 900`).

- [ ] **Step 1: Write the failing test** `theme-showcase.test.ts`, using Astro's `experimental_AstroContainer` (`renderToString`). Render it with `serverThemes.slice(0, 2)`; the images come from Task 5, which runs before this task.
  - `renders the first theme's image without JS`: the first `<img>` has no `hidden` attribute and no `loading="lazy"`. The others carry `hidden` and `loading="lazy"`.
  - `renders one swatch button per theme`: `button[data-theme-id]` count equals `themes.length`; each `aria-pressed` is `"true"` only on the first; each button's text is the label.

- [ ] **Step 2: Run to verify failure**

Run: `cd site && npm test`
Expected: FAIL.

- [ ] **Step 3: Implement the components.** `ThemeShowcase` has an inline `<script>` scoped by `id`. Clicking a swatch toggles `hidden` on the images and sets `aria-pressed`, and nothing else. Swatches are daisyUI `btn btn-sm` with a coloured dot (`style={`background:${swatch}`}`). The phone aspect wraps the image in the existing phone-frame markup from `Player.astro`. `Install` renders the three numbered steps with copy from the spec, a `<pre><code>` of `composeYaml`, a copy button (an inline script using `navigator.clipboard.writeText` that shows "Copied" for 2s), and a "Full guide" link to `https://docs.mydia.dev/latest/`. `Sources` dims `soon` tiles (`opacity-50`, with a "Coming soon" `badge badge-ghost`).

- [ ] **Step 4: Run to verify pass**

Run: `cd site && npm test`
Expected: PASS.

- [ ] **Step 5: Commit**: "feat(site): product card, sources, theme showcase and install components"

### Task 4: Pages, nav and copy

**Files:**
- Modify: `site/src/pages/index.astro`, `site/src/components/Hero.astro`, `site/src/components/Header.astro`, `site/src/components/Footer.astro` (docs URL, if present), `site/src/layouts/Base.astro` (add `description` prop to `<meta name="description">`), `site/src/pages/download.astro` (title copy "Download Mydia Player" is already right; only its `Base` title/description)
- Create: `site/src/pages/player.astro`, `site/src/pages/server.astro`
- Modify: `README.md` (Plex/Jellyfin sentence; name the Phoenix app "Mydia Server" in the intro)

**Interfaces:**
- Consumes: all Task 3 components, Task 2 data.

- [ ] **Step 1: Write every page.** Section order and copy come from the spec sections "Homepage", "`/player`" and "`/server`", word for word where the spec quotes copy. The homepage player `ProductCard` gets `id="player"`. Header `navLinks`: Player `/player`, Server `/server`, Download `/download`, Blog `/blog`, Docs `https://docs.mydia.dev/latest/` (external), GitHub (external). Titles and descriptions:
  - `/` gets "Mydia: a player for every server, and a server for your library"
  - `/player` gets "Mydia Player: one app for Plex, Jellyfin and Mydia Server"
  - `/server` gets "Mydia Server: self-hosted library and automation"

- [ ] **Step 2: Verify each of the six `/player` feature claims against the player code before keeping it.** These are every platform, offline downloads, Chromecast and DLNA casting, Plex Home profiles, hardware-accelerated playback, and continue watching across servers. Search `player/lib` for each. Replace any claim that doesn't hold with one that does; don't soften it. List the evidence (one file path per claim) in the commit body.

- [ ] **Step 3: Delete the old `site/public/img/{homepage,movies,tv-shows,calendar,series,player-home,player-shows,player-desktop}.png`**, now that `Screenshots.astro` and the cards use `src/assets/screenshots/`.

Run: `grep -rn "/img/\(homepage\|movies\|tv-shows\|calendar\|series\|player-\)" site/src`
Expected: no output.

- [ ] **Step 4: Grep the copy rules**

Run: `grep -rnE "—|iroh|QUIC|LiveView|GraphQL|Stash|getmydia.github.io" site/src`
Expected: no output.

- [ ] **Step 5: Build**

Run: `cd site && npm run build && npm test`
Expected: build succeeds; all tests pass.

- [ ] **Step 6: Commit** (include `README.md`): "feat(site): split the site into Mydia Player and Mydia Server pages"

### Task 5: Capture script and new screenshots

**Files:**
- Modify: `assets/screenshots.js`, `take-screenshots`
- Create (generated): `screenshots/*.png` (replaced), `site/src/assets/screenshots/*.png`

**Interfaces:**
- Consumes: theme ids and image filenames from Task 2's `themes.ts`. The script keeps its own copy of the two id lists, in Global Constraints order, because a CommonJS script cannot import TS. Task 2's tests already guard the ids against the app.
- Produces these files in `site/src/assets/screenshots/`:
  - `server-theme-<id>.png` (1920x1080) for each curated server theme
  - `player-theme-<id>.png` (1920x880 desktop) and `player-theme-<id>-phone.png` (448x950 @2x) for each preset
  - `homepage.png`, `movies.png`, `tv-shows.png`, `calendar.png`, `series.png`, `player-home.png`, `player-shows.png`, `player-desktop.png`, the same names the README uses

- [ ] **Step 1: Replace `setTheme(page, theme)`** with `applyServerTheme(page, id, base, scheme)`. It sets `data-theme`, `data-color-scheme` and `style.backgroundColor` on `document.documentElement`. Call it after every `page.goto`, since the page reloads, and then wait 500 ms. Shots without a theme use `mydia-dark`.
- [ ] **Step 2: Add the server theme set:** the dashboard `/` once per curated id, saved as `server-theme-<id>.png`.
- [ ] **Step 3: Add the player theme set.** For each preset, open a fresh context and run `addInitScript` to set `localStorage['mydia_auth_theme_preset'] = <id>` before boot. Then capture `#/` at both sizes, using the existing `PLAYER_BOOT_MS` boot wait.
- [ ] **Step 4: Write every file to both `OUTPUT_DIR` (`../screenshots`) and `SITE_OUTPUT_DIR`** (default `../site/src/assets/screenshots`). Update the header comment in `take-screenshots` so it says to run `./dev mix mydia.demo_seed` on a fresh DB first.
- [ ] **Step 5: Capture.** Against the Task 1 smoke-test stack, run `BASE_URL=http://localhost:<port> ./take-screenshots`.
Expected: no `⚠ Warning` lines. Open every file to check two things: no real titles anywhere, and each theme visibly differs.
- [ ] **Step 6: Commit**: "docs: retake screenshots against the demo library, with theme sets"

### Task 6: Link check and visual review

**Files:**
- Create: `site/scripts/check-links.mjs`
- Modify: `site/package.json` (`"check-links": "node scripts/check-links.mjs"`)

- [ ] **Step 1: Write `check-links.mjs`.** It walks `dist/**/*.html` and collects internal `href`s, which are root-relative or `#`-only. Each path must resolve to a file in `dist`, either `<path>/index.html` or `<path>.html`. Each `#fragment` must match an `id=` in the target page. It always checks `/#player`, `/server#install` and `/download#platforms` even if nothing links them. On failure it prints every broken link and exits 1.
- [ ] **Step 2: Run it**

Run: `cd site && npm run build && npm run check-links`
Expected: `0 broken links`.

- [ ] **Step 3: Visual review screenshots.** Run `npm run preview` and use a throwaway Node script, not committed, that requires `playwright`. It captures `/`, `/player`, `/server` and `/download`, full page, at 390x844 and 1440x900, `deviceScaleFactor: 2`, into `/tmp/mydia-site-review-01KrqR7j/`. Click one swatch on each showcase and capture again. Send the images to the maintainer and wait for approval before opening the PR.
- [ ] **Step 4: Commit**: "test(site): check internal links and anchors in the built site"

### Task 7: Pre-PR checks

- [ ] **Step 1:** Run `./dev mix precommit` in five foreground chunks, as `test/README.md` advises; only the new Elixir code is at risk. Then `cd site && npm test && npm run build && npm run check-links`.
- [ ] **Step 2:** Get co-change partners and tests at risk for the changed files. Use Repowise `get_risk` with `changed_files` from `git diff --name-only origin/master...`. Address any `missing_cochanges`, or note why each doesn't apply.
- [ ] **Step 3:** Run `git diff --stat origin/master...`. Every file should belong to a task above.
