defmodule MydiaWeb.Features.AddConfigFlowTest do
  @moduledoc """
  Browser regression for #465, the add dialog being covered and clipped, now
  retargeted at the merged Configure Before Adding dialog.

  Three earlier fixes moved a z-index around and the unit test asserted that
  the class was present, which it always was. What the class could not show is
  that the sidebar is `z-40`, the mobile dock is `z-50` and the sticky header
  is `z-30`, so a `z-20` menu lost to all of them, ran off the left edge on
  first-column cards and hung below the fold on lower rows.

  This test asks the browser what actually paints on top, across the whole
  dialog rectangle, at a desktop and a mobile viewport.

  This file used to drive a two-step flow: a caret opened `LibraryComponents.
  library_picker_dialog/1` ("Add to which library?"), and that dialog carried
  a "Configure..." entry to reach the dialog under test. The picker is gone;
  `[data-test="add-config-caret"]` now opens `MydiaWeb.AddMediaComponents.
  add_config_modal/1` directly, so every test below drives that dialog in one
  step and, where an old test picked a library from a menu, submits
  `#add-config-form` naming `config[library_path_id]` instead.
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  import Mydia.SettingsFixtures

  alias Mydia.Metadata.Cache

  # elementFromPoint answers the exact question the bug is about: given a
  # point inside the dialog, which element does the user's click land on? Any
  # answer outside the dialog is something painting over it.
  @probe """
  const box = document.querySelector('#add-config-modal .modal-box');
  if (!box) { return ['no dialog rendered']; }
  const r = box.getBoundingClientRect();
  const vw = document.documentElement.clientWidth;
  const vh = document.documentElement.clientHeight;
  const problems = [];
  if (r.width < 1 || r.height < 1) { return ['dialog has no size']; }
  if (r.left < 0) problems.push('off-screen left by ' + Math.round(-r.left));
  if (r.top < 0) problems.push('off-screen top by ' + Math.round(-r.top));
  if (r.right > vw) problems.push('off-screen right by ' + Math.round(r.right - vw));
  if (r.bottom > vh) problems.push('off-screen bottom by ' + Math.round(r.bottom - vh));
  const seen = {};
  for (let x = r.left + 3; x < r.right - 3; x += 10) {
    for (let y = r.top + 3; y < r.bottom - 3; y += 10) {
      const t = document.elementFromPoint(x, y);
      if (t && !box.contains(t) && t !== box) {
        const key = t.tagName.toLowerCase() + (t.id ? '#' + t.id : '');
        if (!seen[key]) { seen[key] = true; problems.push('covered by ' + key); }
      }
    }
  }
  return problems;
  """

  # The probe above can never fail on its own: daisyUI centers .modal-box
  # within the fixed, full-viewport .modal, so at these two content sizes
  # the box's own rectangle never reaches into the sidebar's or dock's
  # screen space, regardless of the dialog's z-index. What actually competes
  # with the chrome is the full-viewport .modal LAYER itself, which covers
  # the sidebar and dock entirely and, per daisyUI, is pointer-events: auto
  # while open. This probe hit-tests the CENTRE of a given chrome element and
  # asserts the dialog (or one of its descendants, e.g. the modal-backdrop)
  # wins there instead of the chrome, the comparison a z-index downgrade can
  # actually break.
  @chrome_probe """
  const chromeSelector = arguments[0];
  const dialog = document.querySelector('#add-config-modal');
  if (!dialog) { return ['no dialog rendered']; }
  const chromeEl = document.querySelector(chromeSelector);
  if (!chromeEl) { return ['chrome element not found: ' + chromeSelector]; }
  const r = chromeEl.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) { return ['chrome element has no size: ' + chromeSelector]; }
  const cx = r.left + r.width / 2;
  const cy = r.top + r.height / 2;
  const winner = document.elementFromPoint(cx, cy);
  if (!winner) { return ['nothing returned by elementFromPoint at chrome centre']; }
  if (winner === dialog || dialog.contains(winner)) { return []; }
  const key = winner.tagName.toLowerCase() + (winner.id ? '#' + winner.id : '');
  return ['chrome centre (' + chromeSelector + ') is won by ' + key + ' instead of the add-config dialog'];
  """

  setup do
    bypass = Bypass.open()

    # Capture whatever was configured before this test so on_exit can put it
    # back rather than deleting the key outright. metadata_relay_url/0 now
    # prefers this application env key over METADATA_RELAY_URL, so a bare
    # delete_env would erase a real config value for every test that runs
    # afterwards in this VM if one is ever set.
    previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")
    Cache.clear()

    on_exit(fn ->
      case previous_metadata_relay_url do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end

      Cache.clear()
    end)

    # Bypass returns JSON only if the content type says so; Req leaves the
    # body as a raw string otherwise and the relay parser then sees no
    # "results" key and yields an empty grid.
    Bypass.stub(bypass, "GET", "/tmdb/movies/trending", fn conn ->
      results =
        for i <- 1..12 do
          %{
            "id" => 900_000 + i,
            "title" => "Fixture Movie #{i}",
            "release_date" => "2026-01-01",
            "vote_average" => 8.0,
            "poster_path" => nil,
            "overview" => ""
          }
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"page" => 1, "total_pages" => 1, "results" => results})
      )
    end)

    # DiscoverLive's genre filter calls Relay.fetch_genres/2, which builds
    # "/tmdb/genre/movie" (singular, reversed word order from what it looks
    # like) rather than "/tmdb/movies/genres". Left unstubbed, every request
    # 500s and Req's `retry: :transient` step retries it three times with
    # backoff inside the LiveView's synchronous handle_info, which starves
    # the process long enough for the dialog's click to miss Wallaby's wait
    # window.
    Bypass.stub(bypass, "GET", "/tmdb/genre/movie", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"genres" => []}))
    end)

    # login_as_admin/1 signs in through the real login form, and the server
    # redirects to "/" before we ever navigate to /discover. DashboardLive's
    # mount fires both a trending-movies and a trending-tv load, so the tv
    # endpoint needs a stub too or the same retry storm happens there instead.
    Bypass.stub(bypass, "GET", "/tmdb/tv/trending", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"page" => 1, "total_pages" => 1, "results" => []}))
    end)

    # "submitting the form adds the title" chooses the first card, i.e. id
    # 900001, the first result above, and submits the configure form for it.
    # The dialog closes synchronously, but
    # MediaAddHelpers.handle_add_media_to_library/5 then fetches that movie's
    # full TMDB details before writing the media_items row, so that also
    # needs a stub or the same retry storm follows it. A literal path rather
    # than a ":id" wildcard, so it cannot also swallow "/tmdb/movies/trending"
    # and break the stub above.
    Bypass.stub(bypass, "GET", "/tmdb/movies/900001", fn conn ->
      body = %{
        "id" => 900_001,
        "title" => "Fixture Movie 1",
        "release_date" => "2026-01-01",
        "overview" => "",
        "credits" => %{"cast" => [], "crew" => []},
        "genres" => []
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    # The caret renders unconditionally now (Task 5 deleted the
    # `length(@libraries) > 1` gate), so a single library would do for the
    # geometry tests below. Two are seeded anyway so the library select in
    # the submit test has a real, non-trivial choice to make.
    library_a = library_path_fixture(%{path: "/media/add-config-a", type: "movies"})
    library_b = library_path_fixture(%{path: "/media/add-config-b", type: "movies"})

    %{library_a: library_a, library_b: library_b}
  end

  # The first card is the leftmost in the top row, which is the geometry that
  # failed: the old menu opened left into the sidebar and, on mobile, straight
  # off the edge of the viewport.
  defp open_first_config(session) do
    session
    |> visit_liveview("/discover")
    |> assert_has(Query.css(~s([data-test="add-config-caret"]), minimum: 1))
    # Tried a real click(Query.css(..., at: 0)) here first: it reaches the
    # caret and opens the dialog at the 1400x1000 desktop viewport, but at
    # the 390x844 mobile viewport used below it produces zero DOM click
    # events (confirmed empirically: the assertion after it finds the dialog
    # never opens). js_click/2 is the documented escape hatch for exactly
    # that case, a phx-click button a real click genuinely cannot reach, so
    # it is used here instead of Query-based click. js_click no longer
    # carries an implicit sleep, so the assert_has immediately below is
    # load-bearing: it is what actually waits for the dialog to open,
    # polling up to max_wait_time rather than a fixed delay.
    |> js_click(~s([data-test="add-config-caret"]))
    |> assert_has(Query.css("#add-config-modal[open]"))
  end

  # Sets the library select's value directly rather than driving a native
  # `<select>` through Wallaby's Query.select/Query.option: the "Root Folder"
  # label sits beside the select as a sibling, not wrapped around it, so
  # there is no `<label for>` association for Query.select to resolve by
  # text. LiveView reads the form's live DOM value at submit time, not at
  # some earlier change event, so no synthetic change event is required here.
  defp choose_library(session, library_id) do
    execute_script(
      session,
      """
      var el = document.querySelector('#add-config-form select[name="config[library_path_id]"]');
      if (el) { el.value = arguments[0]; }
      """,
      [library_id]
    )

    session
  end

  defp probe(session) do
    execute_script(session, @probe, [], fn problems -> send(self(), {:probe, problems}) end)

    assert_receive {:probe, problems}, 5_000
    problems
  end

  defp chrome_probe(session, chrome_selector) do
    execute_script(session, @chrome_probe, [chrome_selector], fn problems ->
      send(self(), {:chrome_probe, problems})
    end)

    assert_receive {:chrome_probe, problems}, 5_000
    problems
  end

  @tag :feature
  test "the dialog is fully visible and unobstructed on a desktop viewport", %{session: session} do
    session
    |> login_as_admin()
    |> resize_window(1400, 1000)
    |> open_first_config()

    assert probe(session) == []
    # The sidebar is always visible at this width (lg:drawer-open), so its
    # centre is a real point of contention with the full-viewport dialog
    # layer, not just its centered box.
    assert chrome_probe(session, ".drawer-side") == []
  end

  @tag :feature
  test "the dialog is fully visible and unobstructed on a mobile viewport", %{session: session} do
    session
    |> login_as_admin()
    |> resize_window(390, 844)
    |> open_first_config()

    assert probe(session) == []
    # The sidebar drawer is closed (and not hit-testable) by default at this
    # width, but the mobile dock is a real, painted fixed element here, so
    # it is the chrome that actually contends with the dialog layer.
    assert chrome_probe(session, "#mobile-dock") == []
  end

  @tag :feature
  test "the open dialog is fully visible and nothing is painted over it",
       %{session: session} do
    session
    |> login_as_admin()
    |> resize_window(390, 844)
    |> open_first_config()

    # add_config_modal/1's own @doc explains why this is a page-level
    # `.modal` (`z-[1000]`, position: fixed, inset: 0) rather than an
    # anchored dropdown: the deleted picker's own dialog made the same
    # choice for the same reason, an earlier :focus-within dropdown lost to
    # the z-40 sidebar and z-50 dock, which is exactly the class of bug
    # `MydiaWeb.FeatureCase.Geometry`'s `assert_in_viewport/2` and
    # `refute_covered/2` exist to catch. @probe and chrome_probe/1 above
    # already hit-test the same question by hand for this exact dialog. This
    # test asks it again with the shared, canonical helpers instead of a
    # one-off script, so the coverage survives even if the hand-rolled
    # probes above are ever deleted, and so a future regression back to an
    # anchored dropdown is still caught here.
    session
    |> assert_in_viewport(~s(#add-config-modal .modal-box))
    |> refute_covered(~s(#add-config-modal .modal-box))
  end

  @tag :feature
  test "submitting the form with a chosen library adds the title and closes the dialog",
       %{session: session, library_a: library_a} do
    session
    |> login_as_admin()
    |> resize_window(1400, 1000)
    |> open_first_config()
    |> choose_library(library_a.id)
    |> click(Query.css(~s(#add-config-form button[type="submit"])))
    |> refute_has(Query.css("#add-config-modal[open]"))

    # The dialog closes synchronously on submit, but the add itself completes
    # in a handle_info the browser interaction does not wait on: it fetches
    # the movie's own TMDB details (stubbed above) before writing the row.
    added =
      eventually(
        fn ->
          case Mydia.Media.get_media_item_by_tmdb(900_001) do
            nil -> :error
            item -> {:ok, item}
          end
        end,
        description: "a media item for tmdb_id=900001 to be created"
      )

    assert added.library_path_id == library_a.id
  end
end
