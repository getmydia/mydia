# Browser Testing

Mydia's browser tests use [Wallaby](https://hexdocs.pm/wallaby), which drives a real
headless Chrome from ExUnit. Tests are written in Elixir and run inside the Ecto
sandbox, so each one gets a transaction that is rolled back afterwards.

There is no Playwright test suite. An earlier one existed under `assets/e2e/`; it
depended on `/api/test/*` seeding endpoints that were never built, and it was
removed. `@playwright/test` remains in `assets/package.json` solely for
`screenshots.js`.

## Running

```bash
./dev feature-test                                            # the whole suite
./dev feature-test test/mydia_web/features/dock_nav_test.exs --include feature
WALLABY_HEADLESS=false ./dev feature-test                     # watch it run
```

Pass `--include feature` only alongside a file path. On its own it runs the entire
project suite rather than just the browser tests, which takes about ten minutes.
Plain `./dev feature-test` with no arguments is the way to run all browser tests.

Assets must be built or every test fails for an unrelated reason: a worktree with
no `priv/static/assets/` serves a 404 for `app.js`, so the LiveView socket never
connects. CI does this before running the suite; do it once locally too.

```bash
./dev mix compile && ./dev mix assets.deploy
```

Feature tests are excluded from `./dev test` by the `:feature` tag, because they
need chromedriver. devenv provides chromium and chromedriver in-shell and sets
`CHROME_PATH` / `CHROMEDRIVER_PATH`, so no extra setup is required.

Screenshots of failures land in `tmp/wallaby_screenshots/`. CI uploads them as an
artifact on the `Test / E2E Browser` job.

## What belongs in a browser test

Browser tests are the slowest tests in the repo. A test earns its place here only
if it exercises something no other layer can reach.

**Put it in the browser when it depends on client-side JavaScript.** The
`phx-hook` modules in `assets/js/` are the clearest case: `DockNav`,
`ThemeToggle`, `PersistedCheckbox`, `VideoPlayer`, `PlexOAuth`, `DownloadFile`.
`Phoenix.LiveViewTest` never executes them.

**Put it in the browser when it is about layout.** Whether one element is painted
over another, or clipped by its scroll container, is only answerable by a real
rendering engine. See "Geometry assertions" below.

**Do not put it in the browser to check who can reach which URL.** That is decided
by a plug and an `on_mount` hook. `test/mydia_web/route_authorization_test.exs`
covers the whole route/role matrix in milliseconds. Add a row there instead.

**Do not put it in the browser to check a form handler.** A POST is a POST.
`test/mydia_web/controllers/session_controller_test.exs` is the model.

## Never sleep

`test/mydia_web/features/no_sleep_test.exs` fails the build if a feature test
calls `:timer.sleep`. This is enforced because the suite once carried 10 sleeps,
including a flat 3-second wait repeated across 37 call sites.

Wallaby's `Query` assertions already retry until `:max_wait_time` (10s, set in
`config/test.exs`). So the fix for "the DOM was not ready yet" is to assert on the
thing you are waiting for:

```elixir
# No. The sleep is doing the waiting, and 500ms is a guess.
:timer.sleep(500)
assert Wallaby.Browser.has_text?(session, "Saved")

# Yes. has_text?/2 retries until it appears or max_wait_time elapses.
assert Wallaby.Browser.has_text?(session, "Saved")
```

To wait for a LiveView socket, use `wait_for_liveview/1`. It blocks on
`[data-phx-main].phx-connected`, the class LiveView adds when the join succeeds.
Do not assert on `data-phx-main` alone: it is server-rendered and present before
the socket connects, so it proves nothing.

**`wait_for_liveview/1` is not enough after clicking something that navigates.**
`<.link navigate>` performs client-side pushState. The WebDriver click returns
before the destination mounts, so `wait_for_liveview/1` matches the *stale* root
immediately and any following `assert_path` reads the old path. Poll the path
first:

```elixir
session
|> click(Query.css(~s(a[href="/movies"])))

eventually(
  fn ->
    if Wallaby.Browser.current_path(session) == "/movies", do: {:ok, true}, else: :error
  end,
  description: "navigation to /movies"
)

session |> wait_for_liveview()
```

**Viewport matters.** The headless window is small by default, and this app hides
components at breakpoints. The dock is `lg:hidden`, so it renders only *below*
1024px — resizing up hides it. Set the viewport the component actually needs:

```elixir
Wallaby.Browser.resize_window(session, 390, 844)   # mobile: dock, library picker
```

For state the browser cannot show you, such as a row a LiveView writes after the
click returns, use `eventually/2`:

```elixir
request =
  eventually(
    fn ->
      case Repo.get_by(MediaRequest, tmdb_id: id) do
        nil -> :error
        request -> {:ok, request}
      end
    end,
    description: "a media request with tmdb_id #{id}"
  )
```

## Geometry assertions

`MydiaWeb.FeatureCase.Geometry` asserts facts about the rendered box. It is
imported automatically by `MydiaWeb.FeatureCase`.

```elixir
session
|> refute_covered(~s([phx-hook="DockNav"]))   # nothing is painted on top
|> assert_in_viewport("#approve-form")        # the rect is on screen
|> refute_clipped("#library-grid")            # the scroll container does not cut it off
```

`refute_covered/2` samples a 3x3 grid across the element's bounding rect and calls
`document.elementFromPoint` at each point. When it fails it names the covering
element, so the message reads "covered by nav.dock" rather than reporting a pixel
count.

This is deliberately not screenshot diffing. Baseline images would drift between a
NixOS dev machine and an ubuntu-latest CI runner over nothing but font rendering,
and a pixel count does not tell you what broke.

## Writing a test

```elixir
defmodule MydiaWeb.Features.MyThingTest do
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  @tag :feature
  test "the thing works", %{session: session} do
    login_as_admin(session)

    session
    |> visit("/")
    |> wait_for_liveview()
    |> click(Query.css("#my-button"))

    assert Wallaby.Browser.has_text?(session, "It worked")
  end
end
```

`async: false` is required. SQLite does not tolerate concurrent writes.

Available helpers from `MydiaWeb.FeatureCase`: `login/3`, `login_as_admin/1`,
`login_as_user/1`, `login_as_guest/1`, `create_admin_user/1`, `create_test_user/1`,
`create_guest_user/1`, `assert_path/2`, `assert_has_text/2`, `wait_for_liveview/1`,
`eventually/2`, `eval_js/3`, `js_click/2`.

`MydiaWeb.FeatureCase.Geometry`'s `refute_covered/2`, `assert_in_viewport/2`, and
`refute_clipped/2` (see "Geometry assertions" above) are also auto-imported, via
the `using` block in `test/support/feature_case.ex`.
