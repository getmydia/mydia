defmodule MydiaWeb.MediaLive.Show.SeasonOrderUiTest do
  # async: false — connected LiveView tests hit the Postgres non-shared
  # sandbox, and this file also hits `Mydia.Metadata.Cache`, a shared ETS
  # table.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Media
  alias Mydia.Media.Episode
  alias Mydia.Repo

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin)}
  end

  defp oversized_show(tvdb_id) do
    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Black Clover",
        tvdb_id: tvdb_id,
        metadata_source: :tvdb,
        season_order: nil
      })

    for n <- 1..170 do
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: n,
        absolute_number: n,
        provider_episode_id: "#{n}"
      })
    end

    show
  end

  test "suggests an alternative ordering for a 170-episode season", %{conn: conn} do
    tvdb_id = System.unique_integer([:positive])
    show = oversized_show(tvdb_id)
    stub_tvdb_orderings(tvdb_id, official: 170, dvd: [51, 51, 52, 16])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    assert has_element?(view, "#season-order-suggestion")

    assert has_element?(
             view,
             "#season-order-suggestion",
             "four seasons of 51, 51, 52 and 16"
           )
  end

  # These three "no suggestion" tests each stub a real, fetchable "dvd"
  # alternative for an otherwise-oversized TVDB show, so that if the
  # condition each test names were deleted from
  # `eligible_for_season_order_suggestion?/1`, the lookup would actually run
  # and find a real alternative — making the banner appear and the test
  # fail. Without the stub (and the matching `render_async`), a passing
  # `refute` would prove nothing: it would pass identically whether the
  # guard worked or the async lookup simply hadn't run yet.
  test "no suggestion once an ordering has been chosen, even with a real alternative available",
       %{conn: conn} do
    tvdb_id = System.unique_integer([:positive])
    show = oversized_show(tvdb_id)
    {:ok, show} = Media.update_media_item(show, %{season_order: :official})
    stub_tvdb_orderings(tvdb_id, official: 170, dvd: [51, 51, 52, 16])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    refute has_element?(view, "#season-order-suggestion")
  end

  test "no suggestion for a normally sized show, even with a real alternative available", %{
    conn: conn
  } do
    tvdb_id = System.unique_integer([:positive])

    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Normal",
        tvdb_id: tvdb_id,
        metadata_source: :tvdb,
        season_order: nil
      })

    for n <- 1..12 do
      episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: n})
    end

    stub_tvdb_orderings(tvdb_id, official: 170, dvd: [51, 51, 52, 16])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    refute has_element?(view, "#season-order-suggestion")
  end

  test "no suggestion when TVDB has no alternative ordering to offer", %{conn: conn} do
    tvdb_id = System.unique_integer([:positive])
    show = oversized_show(tvdb_id)
    stub_tvdb_orderings(tvdb_id, official: 170, dvd: [])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    refute has_element?(view, "#season-order-suggestion")
  end

  test "the persistent selector is present on a normally sized TVDB show", %{conn: conn} do
    show = media_item_fixture(%{type: "tv_show", title: "Normal", metadata_source: :tvdb})

    for n <- 1..12 do
      episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: n})
    end

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    refute has_element?(view, "#season-order-suggestion")
    assert has_element?(view, "#season-order-select")

    # The options' `value`s are the ordering atoms rendered as plain option
    # values (`:official` -> "official", etc), and the show's nil
    # `season_order` (never asked) selects "official", not nothing.
    assert has_element?(view, "#season-order-select option[value=official]", "Aired order")
    assert has_element?(view, "#season-order-select option[value=dvd]", "DVD order")
    assert has_element?(view, "#season-order-select option[value=absolute]", "Absolute order")
    assert has_element?(view, "#season-order-select option[value=official][selected]")
  end

  test "picking a different ordering from the persistent selector switches to it", %{conn: conn} do
    tvdb_id = System.unique_integer([:positive])
    show = oversized_show(tvdb_id)
    stub_tvdb_orderings(tvdb_id, official: 170, dvd: [51, 51, 52, 16])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    view
    |> element("#season-order-form")
    |> render_change(%{"order" => "dvd"})

    assert has_element?(view, "#flash-info", "Switched to DVD order")
    refute has_element?(view, "#season-order-suggestion")

    reloaded = Media.get_media_item!(show.id)
    assert reloaded.season_order == :dvd
  end

  test "no ordering controls for a TMDB-sourced show", %{conn: conn} do
    show = media_item_fixture(%{type: "tv_show", title: "Tmdb Only", metadata_source: :tmdb})

    for n <- 1..170 do
      episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: n})
    end

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    refute has_element?(view, "#season-order-suggestion")
    refute has_element?(view, "#season-order-select")
  end

  test "accepting the suggestion switches to the DVD ordering, remaps episodes, and retires the banner",
       %{conn: conn} do
    tvdb_id = System.unique_integer([:positive])
    show = oversized_show(tvdb_id)
    stub_tvdb_orderings(tvdb_id, official: 170, dvd: [51, 51, 52, 16])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    assert has_element?(view, "#season-order-suggestion")

    view |> element("#season-order-accept") |> render_click()

    refute has_element?(view, "#season-order-suggestion")
    assert has_element?(view, "#flash-info", "Switched to DVD order")

    episodes =
      Episode
      |> where([e], e.media_item_id == ^show.id)
      |> order_by([e], asc: e.provider_episode_id)
      |> select([e], {e.season_number, e.episode_number, e.provider_episode_id})
      |> Repo.all()

    counts =
      episodes
      |> Enum.group_by(fn {season_number, _, _} -> season_number end)
      |> Enum.sort_by(fn {season_number, _} -> season_number end)
      |> Enum.map(fn {_season_number, group} -> length(group) end)

    assert counts == [51, 51, 52, 16]

    reloaded = Media.get_media_item!(show.id)
    assert reloaded.season_order == :dvd
  end

  test "dismissing the suggestion keeps aired order and retires the banner", %{conn: conn} do
    tvdb_id = System.unique_integer([:positive])
    show = oversized_show(tvdb_id)
    stub_tvdb_orderings(tvdb_id, official: 170, dvd: [51, 51, 52, 16])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    view |> element("#season-order-dismiss") |> render_click()

    refute has_element?(view, "#season-order-suggestion")

    reloaded = Media.get_media_item!(show.id)
    assert reloaded.season_order == :official

    # Aired order describes the same single season it started with — nothing
    # about the episodes' actual numbering should have moved.
    episode_numbers =
      Episode
      |> where([e], e.media_item_id == ^show.id)
      |> select([e], e.episode_number)
      |> Repo.all()
      |> Enum.sort()

    assert episode_numbers == Enum.to_list(1..170)
  end

  test "the dismiss button retires the banner even when episodes are missing provider ids", %{
    conn: conn
  } do
    tvdb_id = System.unique_integer([:positive])

    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "No Provider Ids Dismiss",
        tvdb_id: tvdb_id,
        metadata_source: :tvdb,
        season_order: nil
      })

    for n <- 1..170 do
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: n,
        provider_episode_id: nil
      })
    end

    stub_tvdb_orderings(tvdb_id, official: 170, dvd: [51, 51, 52, 16])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    assert has_element?(view, "#season-order-suggestion")

    # "Keep aired order" is a bookkeeping write (target already equals the
    # show's effective ordering), so it must succeed without ever touching
    # the relay or `remap/3` — unlike "Use DVD ordering" on this same show,
    # which needs a real mapping and would hit :missing_provider_ids.
    view |> element("#season-order-dismiss") |> render_click()

    refute has_element?(view, "#season-order-suggestion")
    assert has_element?(view, "#flash-info", "Keeping Aired order")

    reloaded = Media.get_media_item!(show.id)
    assert reloaded.season_order == :official
  end

  test "a DVD ordering covering fewer episodes than the show refuses instead of partially remapping",
       %{conn: conn} do
    tvdb_id = System.unique_integer([:positive])
    show = oversized_show(tvdb_id)
    # Only the first 51 of the show's 170 episodes appear anywhere in the
    # stubbed "dvd" ordering — the other 119 have no target coordinates.
    stub_tvdb_orderings(tvdb_id, official: 170, dvd: [51])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    view |> element("#season-order-accept") |> render_click()

    assert has_element?(view, "#flash-error", "missing 119")

    reloaded = Media.get_media_item!(show.id)
    assert reloaded.season_order == nil

    # Nothing moved: refusing must be all-or-nothing, not "remap the covered
    # 51 and strand the rest" — a half-remapped show under a season_order
    # that claims otherwise is worse than declining.
    episode_numbers =
      Episode
      |> where([e], e.media_item_id == ^show.id)
      |> select([e], e.episode_number)
      |> Repo.all()
      |> Enum.sort()

    assert episode_numbers == Enum.to_list(1..170)
  end

  test "missing provider ids produce an actionable flash instead of a crash", %{conn: conn} do
    tvdb_id = System.unique_integer([:positive])

    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "No Provider Ids",
        tvdb_id: tvdb_id,
        metadata_source: :tvdb,
        season_order: nil
      })

    for n <- 1..170 do
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: n,
        provider_episode_id: nil
      })
    end

    stub_tvdb_orderings(tvdb_id, official: 170, dvd: [51, 51, 52, 16])

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    view |> element("#season-order-accept") |> render_click()

    assert has_element?(view, "#flash-error", "Refresh this show")

    reloaded = Media.get_media_item!(show.id)
    assert reloaded.season_order == nil
  end

  # Stubs the TVDB series-extended endpoint with an "official" ordering of
  # one season (`official` episodes) and a "dvd" ordering split across
  # `dvd`'s season sizes, plus each season's extended endpoint. Both
  # orderings describe the *same* episodes (ids 1..sum(dvd), matching
  # `oversized_show/1`'s provider_episode_id fixtures), just grouped
  # differently — exactly what makes a real TVDB alternative ordering safe to
  # switch to losslessly.
  #
  # Rather than pointing the LiveView's own relay config at Bypass (there is
  # no seam for that — `metadata_config` defaults from
  # `Mydia.Metadata.default_relay_config/0` inside `mount/3`), this warms
  # `Mydia.Metadata.Cache` through a Bypass-pointed config first. Cache keys
  # do not include the base URL, so the LiveView's later call against the
  # real default config reads the stubbed data back with no outbound
  # request — same trick as `FranchiseSectionTest.warm_collection_cache/2`.
  defp stub_tvdb_orderings(tvdb_id, official: official_count, dvd: dvd_counts) do
    bypass = Bypass.open()

    relay = Mydia.Metadata.default_relay_config()
    bypass_config = %{relay | base_url: "http://localhost:#{bypass.port}"}

    official_season_id = System.unique_integer([:positive])
    dvd_season_ids = Enum.map(dvd_counts, fn _ -> System.unique_integer([:positive]) end)

    Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
      seasons =
        [season_stub(official_season_id, 1, "official")] ++
          (dvd_season_ids
           |> Enum.with_index(1)
           |> Enum.map(fn {id, number} -> season_stub(id, number, "dvd") end))

      json(conn, %{"data" => %{"id" => tvdb_id, "seasons" => seasons}})
    end)

    Bypass.stub(bypass, "GET", "/tvdb/seasons/#{official_season_id}/extended", fn conn ->
      episodes = episodes_json(1..official_count, 1)

      json(conn, %{
        "data" => %{"id" => official_season_id, "number" => 1, "episodes" => episodes}
      })
    end)

    _final_episode_id =
      dvd_season_ids
      |> Enum.zip(dvd_counts)
      |> Enum.with_index(1)
      |> Enum.reduce(1, fn {{season_id, count}, season_number}, next_id ->
        episode_ids = next_id..(next_id + count - 1)

        Bypass.stub(bypass, "GET", "/tvdb/seasons/#{season_id}/extended", fn conn ->
          episodes = episodes_json(episode_ids, season_number)

          json(conn, %{
            "data" => %{"id" => season_id, "number" => season_number, "episodes" => episodes}
          })
        end)

        next_id + count
      end)

    warm_ordering_cache(bypass_config, tvdb_id)

    :ok
  end

  defp warm_ordering_cache(bypass_config, tvdb_id) do
    alias Mydia.Metadata.Provider.Relay

    provider_id = to_string(tvdb_id)

    {:ok, raw_seasons} = Relay.fetch_raw_seasons(bypass_config, provider_id)
    {:ok, _} = Relay.fetch_ordering_episodes(bypass_config, provider_id, "official", raw_seasons)
    {:ok, _} = Relay.fetch_ordering_episodes(bypass_config, provider_id, "dvd", raw_seasons)

    :ok
  end

  defp season_stub(id, number, type) do
    %{
      "id" => id,
      "number" => number,
      "name" => "Season #{number}",
      "type" => %{"type" => type}
    }
  end

  defp episodes_json(id_range, season_number) do
    id_range
    |> Enum.with_index(1)
    |> Enum.map(fn {id, number} ->
      %{"id" => id, "number" => number, "seasonNumber" => season_number}
    end)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
