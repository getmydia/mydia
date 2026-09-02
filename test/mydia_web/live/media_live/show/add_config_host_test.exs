defmodule MydiaWeb.MediaLive.Show.AddConfigHostTest do
  @moduledoc """
  The detail page's rails open the merged configure dialog, and its single
  page-level dialog routes the submit to the correct rail.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures
  import MydiaWeb.AuthHelpers
  import Mydia.MetadataCacheHelpers

  setup %{conn: conn} do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    library = library_path_fixture(%{path: "/media/host-a", type: "movies"})

    %{conn: log_in_user(conn, admin_user_fixture()), library: library}
  end

  # A movie whose metadata already carries a collection_id skips the
  # movie-details pointer lookup. `missing_tmdb_id` is not owned, so its card
  # renders the Add split button the caret hangs off. The recommendations cache
  # is warmed empty so the page's unconditional recommendations load resolves
  # offline.
  defp movie_with_franchise_entry do
    collection_id = unique_provider_id()
    own_tmdb_id = unique_provider_id()
    missing_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Harbour Lights",
        year: 1998,
        tmdb_id: own_tmdb_id,
        metadata: %{
          "provider_id" => to_string(own_tmdb_id),
          "provider" => "metadata_relay",
          "media_type" => "movie",
          "title" => "Harbour Lights",
          "collection_id" => collection_id,
          "collection_name" => "Harbour Collection"
        }
      })

    warm_collection_cache(collection_id, [
      %{"id" => own_tmdb_id, "title" => "Harbour Lights", "release_date" => "1998-05-25"},
      %{"id" => missing_tmdb_id, "title" => "Harbour Nights", "release_date" => "2001-07-18"}
    ])

    warm_recommendations_cache(own_tmdb_id, :movie, [])

    {movie, missing_tmdb_id}
  end

  defp movie_with_recommendation do
    source_tmdb_id = unique_provider_id()
    recommended_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Glass Meridian",
        year: 2015,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{
        "id" => recommended_tmdb_id,
        "title" => "Glass Meridian II",
        "release_date" => "2018-12-02",
        "poster_path" => "/p.jpg"
      }
    ])

    warm_movie_details_cache(source_tmdb_id)

    {movie, recommended_tmdb_id}
  end

  # The #460 case: `overlap_tmdb_id` is seeded as both a missing franchise
  # entry and a recommendation, so the same tmdb_id draws a card in both
  # rails at once. The routing decision in `AddConfigEvents.dispatch/3` is
  # keyed on the tmdb_id alone, not on which rail's caret was clicked.
  defp movie_with_overlapping_entry do
    collection_id = unique_provider_id()
    own_tmdb_id = unique_provider_id()
    overlap_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Marrow Station",
        year: 1979,
        tmdb_id: own_tmdb_id,
        metadata: %{
          "provider_id" => to_string(own_tmdb_id),
          "provider" => "metadata_relay",
          "media_type" => "movie",
          "title" => "Marrow Station",
          "collection_id" => collection_id,
          "collection_name" => "Marrow Collection"
        }
      })

    warm_collection_cache(collection_id, [
      %{"id" => own_tmdb_id, "title" => "Marrow Station", "release_date" => "1979-05-25"},
      %{"id" => overlap_tmdb_id, "title" => "Marrow Station II", "release_date" => "1986-07-18"}
    ])

    warm_recommendations_cache(own_tmdb_id, :movie, [
      %{
        "id" => overlap_tmdb_id,
        "title" => "Marrow Station II",
        "release_date" => "1986-07-18",
        "poster_path" => "/p.jpg"
      }
    ])

    {movie, overlap_tmdb_id}
  end

  defp open_config(view, tmdb_id, title) do
    render_hook(view, "open_add_config", %{
      "tmdb_id" => to_string(tmdb_id),
      "media_type" => "movie",
      "title" => title
    })
  end

  # A completed add reaches `Mydia.Media.Add.from_provider/4`, which fetches
  # the added title's own TMDB details directly. That lookup is uncached
  # (unlike the mount-time franchise/recommendations lookups
  # `Mydia.MetadataCacheHelpers` warms above), so it always leaves for the
  # live relay unless redirected here. Left unstubbed, RelayGuard fails the
  # whole suite at exit even though the per-test output says 0 failures. See
  # `stub_added_movie_details/2` below and `dashboard_live/add_config_test.exs`
  # for the same trap and fix.
  defp stub_movie_details(tmdb_id, title) do
    bypass = Bypass.open()
    previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous_metadata_relay_url do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    Bypass.expect(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      body = %{
        "id" => tmdb_id,
        "title" => title,
        "release_date" => "2024-01-01",
        "overview" => "",
        "credits" => %{"cast" => [], "crew" => []},
        "genres" => [],
        "belongs_to_collection" => nil
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    :ok
  end

  # Same shape as `stub_movie_details/2`, but blocks the response until
  # `release_added_movie_details/1` is called. `Add.from_provider/4` runs
  # inside a `start_async/3` task the submit kicks off, and the #460 routing
  # test below asserts which rail's card is still showing "Adding..."
  # immediately after that submit, before the response is released, as proof
  # that the franchise rail (not the recommendations rail) registered the
  # in-flight add. Ported from the deleted `rail_picker_host_test.exs`, whose
  # `stub_added_movie_details/3` did the same for the old two-click picker
  # flow.
  defp stub_added_movie_details(tmdb_id, title) do
    bypass = Bypass.open()
    previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous_metadata_relay_url do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    {:ok, gate} = Agent.start_link(fn -> false end)

    Bypass.stub(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      await_release(gate)

      body = %{
        "id" => tmdb_id,
        "title" => title,
        "release_date" => "2024-01-01",
        "overview" => "",
        "credits" => %{"cast" => [], "crew" => []},
        "genres" => []
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    gate
  end

  defp release_added_movie_details(gate), do: Agent.update(gate, fn _ -> true end)

  # Runs in the Bypass connection process, not the test process, so this
  # sleep only delays that one HTTP response.
  defp await_release(gate) do
    if Agent.get(gate, & &1) do
      :ok
    else
      Process.sleep(5)
      await_release(gate)
    end
  end

  # The add completes in a `handle_async` the submit's `render_hook` round
  # trip does not wait on. Polling for the row also keeps Bypass and the
  # `metadata_relay_url` swap alive (their `on_exit` teardown runs after this
  # test process returns) until the async fetch actually lands. Mirrors
  # `wait_until_media_item/2` in `dashboard_live/add_config_test.exs` and
  # `discover_live/config_modal_test.exs`.
  defp wait_until_media_item(tmdb_id, retries \\ 200)

  defp wait_until_media_item(tmdb_id, 0) do
    flunk("media item for tmdb_id=#{tmdb_id} was not created in time")
  end

  defp wait_until_media_item(tmdb_id, retries) do
    case Mydia.Media.get_media_item_by_tmdb(tmdb_id) do
      nil ->
        Process.sleep(10)
        wait_until_media_item(tmdb_id, retries - 1)

      media_item ->
        media_item
    end
  end

  # Bounded, non-flunking counterpart to `wait_until_media_item/2`, for
  # proving a negative. The async add this polls for either lands quickly
  # (Bypass is loopback, no real network latency) or never lands at all, so a
  # short bound is enough: `false` after it elapses means "never showed up",
  # not "check again later".
  defp media_item_created_within?(tmdb_id, retries \\ 50)

  defp media_item_created_within?(_tmdb_id, 0), do: false

  defp media_item_created_within?(tmdb_id, retries) do
    case Mydia.Media.get_media_item_by_tmdb(tmdb_id) do
      nil ->
        Process.sleep(10)
        media_item_created_within?(tmdb_id, retries - 1)

      _media_item ->
        true
    end
  end

  test "a franchise entry preview renders with no overview", %{conn: conn} do
    {movie, missing_tmdb_id} = movie_with_franchise_entry()

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    html = open_config(view, missing_tmdb_id, "Harbour Nights")

    assert html =~ "Configure Before Adding"
    assert html =~ "Harbour Nights"
    # FranchiseEntry has no overview field, so the overview paragraph must be
    # absent rather than rendering an empty or nil value.
    refute html =~ "line-clamp-3"
  end

  test "submit routes a franchise entry to the franchise rail", %{
    conn: conn,
    library: library
  } do
    {movie, missing_tmdb_id} = movie_with_franchise_entry()
    stub_movie_details(missing_tmdb_id, "Harbour Nights")

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    open_config(view, missing_tmdb_id, "Harbour Nights")

    render_hook(view, "submit_add_config", %{
      "config" => %{
        "library_path_id" => to_string(library.id),
        "monitored" => "true",
        "search_on_add" => "false"
      }
    })

    refute has_element?(view, "#add-config-modal[open]")

    added = wait_until_media_item(missing_tmdb_id)
    assert added.title == "Harbour Nights"
  end

  test "submit routes a recommendation to the recommendations rail", %{
    conn: conn,
    library: library
  } do
    {movie, recommended_tmdb_id} = movie_with_recommendation()
    stub_movie_details(recommended_tmdb_id, "Glass Meridian II")

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    open_config(view, recommended_tmdb_id, "Glass Meridian II")

    render_hook(view, "submit_add_config", %{
      "config" => %{
        "library_path_id" => to_string(library.id),
        "monitored" => "true",
        "search_on_add" => "false"
      }
    })

    refute has_element?(view, "#add-config-modal[open]")

    added = wait_until_media_item(recommended_tmdb_id)
    assert added.title == "Glass Meridian II"
  end

  test "a title in both rails (#460) routes to the franchise rail even when the configure " <>
         "dialog opens from the recommendations card",
       %{conn: conn, library: library} do
    {movie, overlap_tmdb_id} = movie_with_overlapping_entry()
    gate = stub_added_movie_details(overlap_tmdb_id, "Marrow Station II")

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    # Both rails render a card for overlap_tmdb_id. Opening the configure
    # dialog from the recommendations card is the point: routing is decided
    # by franchise membership of the tmdb_id, not by which rail's caret fired
    # the event.
    open_config(view, overlap_tmdb_id, "Marrow Station II")

    render_hook(view, "submit_add_config", %{
      "config" => %{
        "library_path_id" => to_string(library.id),
        "monitored" => "true",
        "search_on_add" => "false"
      }
    })

    # Proof of routing: the franchise rail registered the in-flight add and
    # the recommendations rail did not. The added title's own details fetch
    # is still blocked at this point (see stub_added_movie_details/2), so
    # this in-flight window is guaranteed rather than raced.
    assert has_element?(view, "#franchise-section-item-#{overlap_tmdb_id}", "Adding...")
    refute has_element?(view, "#recommendations-rail-item-#{overlap_tmdb_id}", "Adding...")

    release_added_movie_details(gate)
    render_async(view, 5000)
  end

  test "a forged library flashes and adds nothing", %{conn: conn} do
    {movie, missing_tmdb_id} = movie_with_franchise_entry()

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    open_config(view, missing_tmdb_id, "Harbour Nights")

    html =
      render_hook(view, "submit_add_config", %{
        "config" => %{"library_path_id" => "not-a-real-id", "monitored" => "true"}
      })

    assert html =~ "That library is no longer available"
    assert Mydia.Media.get_media_item_by_tmdb(missing_tmdb_id) == nil
  end

  # Server-side authorization must never depend on a hidden UI element. The
  # caret that opens this dialog is hidden for a guest, but nothing stops a
  # guest client from pushing "submit_add_config" over the socket directly
  # with a valid library id, so the handler itself must reject it too. Mirrors
  # `discover_live/authorization_test.exs`'s "guest users cannot trigger
  # add_to_library event".
  #
  # The added title's metadata fetch is stubbed via the gated
  # `stub_added_movie_details/2`, not the immediate `stub_movie_details/2`:
  # `Add.from_provider/4` runs inside a `start_async/3` task, and an ungated
  # stub lets an incorrectly-gated add complete (fetch, decode, insert) and
  # clear `adding_franchise_tmdb_ids` again before the very next line of test
  # code runs. Verified by hand: an ungated version of the
  # `adding_franchise_tmdb_ids` check below silently passed even with the
  # authorization gate deleted, and only `media_item_created_within?/1`
  # caught the bug - racing the same way `Process.sleep/1` would. Holding the
  # response open until `release_added_movie_details/1` runs, after the
  # deterministic check, is what makes that check race-free rather than
  # merely fast. Without any stub at all, an unauthorized submit that slipped
  # through would still create no media item in this test environment
  # (Mydia.RelayGuard blocks the unstubbed relay call), so the absence of a
  # media item would prove nothing about authorization; with the stub in
  # place, a created media item is attributable only to the authorization
  # gate having been skipped.
  test "a guest cannot submit an add even with a valid library", %{
    conn: conn,
    library: library
  } do
    guest = user_fixture(%{role: "guest"})
    conn = log_in_user(conn, guest)

    {movie, missing_tmdb_id} = movie_with_franchise_entry()
    gate = stub_added_movie_details(missing_tmdb_id, "Harbour Nights")

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    open_config(view, missing_tmdb_id, "Harbour Nights")

    render_hook(view, "submit_add_config", %{
      "config" => %{
        "library_path_id" => to_string(library.id),
        "monitored" => "true",
        "search_on_add" => "false"
      }
    })

    # `submit_add_config/2` populates `adding_franchise_tmdb_ids` (or
    # `adding_recommendation_tmdb_ids`, depending on the rail) synchronously,
    # before it ever dispatches the add - see `AddConfigEvents.dispatch/3` and
    # `FranchiseEvents.add_franchise_movie_with_opts/3`. `missing_tmdb_id` is
    # a franchise entry (`movie_with_franchise_entry/0`), so a
    # correctly-gated guest never reaches the `MapSet.put/2` that would add
    # it to `adding_franchise_tmdb_ids` at all. This is deterministic state
    # available the instant `render_hook/3` returns, made race-free against
    # the incorrectly-gated case by the response gate above rather than
    # merely fast. `dispatch_add/3` runs `Integer.parse/1` before storing the
    # key, so the set holds the raw integer, not the string form the dialog
    # submits.
    refute MapSet.member?(
             :sys.get_state(view.pid).socket.assigns.adding_franchise_tmdb_ids,
             missing_tmdb_id
           )

    release_added_movie_details(gate)

    # Belt-and-braces: the add never dispatched, so it can never persist.
    refute media_item_created_within?(missing_tmdb_id)
  end

  test "the rail caret opens the configure dialog", %{conn: conn} do
    {movie, _recommended} = movie_with_recommendation()

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    assert has_element?(view, "#recommendations-rail [data-test='add-config-caret']")
  end
end
