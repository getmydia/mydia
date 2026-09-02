defmodule MydiaWeb.Features.DiscoverSkeletonHeightParityTest do
  @moduledoc """
  Regression guard for the loading-skeleton height parity fixed in 8034abf67.

  `poster_card_grid_skeleton/1` (poster_card_components.ex) exists only
  because a placeholder card shorter than a real card makes the page collapse
  then re-expand once results land. That premise was verified once by hand in
  a browser; nothing in the committed suite checked it, so a future edit that
  reintroduces a shortfall would pass every existing test. This file is that
  check.

  The skeleton is transient: Discover shows it only until its async data
  fetch resolves, so racing it with a timer would be flaky. Discover's
  DISCONNECTED render always contains the skeleton grid, because
  `DiscoverLive.Index.mount/3` sets `@loading` to `true` outside any
  `connected?/1` check, and `handle_params/3`'s disconnected branch never
  flips it (discover_live/index.ex). That means a plain, cookie-authenticated
  GET of `/discover`, issued from this already-settled, connected page,
  returns a fresh disconnected render containing `#discover-grid-skeleton` -
  a brand-new HTTP response, not a snapshot of transient client state, so
  there is no race to lose.

  The GET runs as a synchronous XMLHttpRequest rather than `fetch`, because
  `Wallaby.Browser.execute_script/4` (`eval_js/3`) evaluates its script
  synchronously and does not await a returned Promise; a plain `fetch` here
  would hand back the Promise itself, not the response.

  The fetched skeleton markup is spliced into the live DOM as a sibling of
  the real `#discover-grid`, under a distinct id
  (`#injected-skeleton-grid`) so it can never be confused with a skeleton
  the live page itself might render. Both elements then exist in the same
  document, theme, and container width at the same instant: no timing race,
  no separate viewport, no separate CSS load.
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  # Long enough to wrap to (at least) two lines at any column width the
  # comfortable-density Discover grid renders in a test browser window, which
  # is the case the original 12px shortfall was calibrated against (a
  # one-line title legitimately measures one line-height shorter).
  @long_title "Whispering Lighthouse of the Furthest Northern Coastline"

  setup do
    # MydiaWeb.FeatureCase's own setup already ran warm_trending_cache(:movie,
    # []) before this callback, populating "trending_movies" and
    # "curated:trending:movie:1" with an empty result. Mydia.Metadata.Cache.fetch/3
    # returns an unexpired cached value without calling the fallback, so
    # warming the same keys again below would silently discard this item and
    # never even reach its own Bypass. Clearing them first forces a real
    # refetch against this call's Bypass instance.
    Mydia.Metadata.Cache.delete("trending_movies")
    Mydia.Metadata.Cache.delete("curated:trending:movie:1")

    Mydia.MetadataCacheHelpers.warm_trending_cache(:movie, [
      %{
        "id" => 900_555_001,
        "title" => @long_title,
        "release_date" => "2024-03-14",
        "poster_path" => "/fictional-poster.jpg",
        "vote_average" => 7.4
      }
    ])

    # DiscoverLive.Index.handle_params/3's connected branch fetches genres
    # whenever @genres is still empty (#530), which it always is on first
    # mount. Left unwarmed, that reaches the live relay through
    # Mydia.RelayGuard, which blocks it and forces the suite to a nonzero
    # exit even though every assertion in this file passes.
    Mydia.MetadataCacheHelpers.warm_genre_cache(:movie, [])

    :ok
  end

  @tag :feature
  test "an injected disconnected-render skeleton card matches a real card's height",
       %{session: session} do
    session
    |> login_as_admin()
    |> visit("/discover")
    |> wait_for_liveview()

    wait_for_real_card(session)

    assert inject_skeleton(session) == "ok"

    assert_same_height(session, "#injected-skeleton-grid .card", "#discover-grid .card")
  end

  @tag :feature
  test "the guard actually fails when the skeleton card falls short", %{session: session} do
    session
    |> login_as_admin()
    |> visit("/discover")
    |> wait_for_liveview()

    wait_for_real_card(session)

    assert inject_skeleton(session) == "ok"

    # Deliberately shrink the injected skeleton card by more than the 1px
    # default tolerance, proving the guard can actually fail rather than
    # silently measuring nothing and passing vacuously - exactly the failure
    # mode this whole test exists to rule out. Restored to its natural size
    # below so this test does not leave a mutated DOM behind for the next
    # assertion in the same session.
    shrink_by_px = 12

    eval_js(session, """
      var el = document.querySelector('#injected-skeleton-grid .card');
      el.dataset.originalHeight = el.getBoundingClientRect().height;
      el.style.height = (el.getBoundingClientRect().height - #{shrink_by_px}) + 'px';
    """)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_same_height(session, "#injected-skeleton-grid .card", "#discover-grid .card")
      end

    assert error.message =~ "injected-skeleton-grid"
    assert error.message =~ "discover-grid .card"
    assert error.message =~ "delta #{shrink_by_px}px"

    eval_js(session, """
      var el = document.querySelector('#injected-skeleton-grid .card');
      el.style.height = el.dataset.originalHeight + 'px';
    """)

    assert_same_height(session, "#injected-skeleton-grid .card", "#discover-grid .card")
  end

  # `warm_trending_cache/2` makes the data available, but the connected mount
  # still fetches it asynchronously via `send(self(), :load_data)`, so the
  # real grid is not guaranteed to exist the instant the socket connects.
  defp wait_for_real_card(session) do
    eventually(
      fn ->
        case eval_js(
               session,
               "return document.querySelectorAll('#discover-grid .card').length;"
             ) do
          n when is_number(n) and n > 0 -> {:ok, n}
          _ -> :error
        end
      end,
      description: "the real Discover grid to render at least one card"
    )
  end

  defp inject_skeleton(session) do
    eval_js(session, """
      var xhr = new XMLHttpRequest();
      xhr.open('GET', '/discover', false);

      try {
        xhr.send(null);
      } catch (e) {
        return 'xhr_error: ' + e;
      }

      if (xhr.status !== 200) { return 'xhr_status_' + xhr.status; }

      var doc = new DOMParser().parseFromString(xhr.responseText, 'text/html');
      var skeleton = doc.querySelector('#discover-grid-skeleton');
      if (!skeleton) { return 'no_skeleton_in_disconnected_render'; }

      var realGrid = document.querySelector('#discover-grid');
      if (!realGrid || !realGrid.parentElement) { return 'no_real_grid_in_live_dom'; }

      var imported = document.importNode(skeleton, true);
      imported.id = 'injected-skeleton-grid';
      realGrid.parentElement.insertBefore(imported, realGrid);

      return 'ok';
    """)
  end
end
