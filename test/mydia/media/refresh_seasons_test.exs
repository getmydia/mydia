defmodule Mydia.Media.RefreshSeasonsTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Events
  alias Mydia.Media

  # Counter slots: 1 = show fetch, 2 = season 1 fetch, 3 = season 2 fetch.
  setup do
    bypass = Bypass.open()
    hits = :counters.new(3, [])

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    tvdb_id = System.unique_integer([:positive])
    first_season = System.unique_integer([:positive])
    second_season = System.unique_integer([:positive])

    Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
      :counters.add(hits, 1, 1)
      json(conn, %{"data" => %{}})
    end)

    Bypass.stub(bypass, "GET", "/tvdb/seasons/#{first_season}/extended", fn conn ->
      :counters.add(hits, 2, 1)
      json(conn, %{"data" => %{"id" => first_season, "number" => 1, "episodes" => []}})
    end)

    Bypass.stub(bypass, "GET", "/tvdb/episodes/:episode_id/extended", fn conn ->
      json(conn, %{"data" => %{"translations" => %{}}})
    end)

    item =
      media_item_fixture(%{
        type: "tv_show",
        title: "Lantern Bay",
        year: 2025,
        tvdb_id: tvdb_id,
        metadata_source: :tvdb,
        metadata: %{
          seasons: [
            %{season_number: 1, tvdb_season_id: first_season},
            %{season_number: 2, tvdb_season_id: second_season}
          ]
        }
      })

    %{bypass: bypass, config: config, hits: hits, item: item, second_season: second_season}
  end

  test "re-reads only the named season and replaces a placeholder title", ctx do
    episode_fixture(%{
      media_item_id: ctx.item.id,
      season_number: 2,
      episode_number: 8,
      title: "TBA "
    })

    stub_second_season(ctx, fn conn -> season_response(conn, ctx, "Harbor Lights") end)

    assert {:ok, [%{season: 2, episode: 8, old: "TBA ", new: "Harbor Lights"}]} =
             Media.refresh_seasons(ctx.item, [2],
               config: ctx.config,
               actor_type: :job,
               actor_id: "airing_episode_refresh"
             )

    assert Media.get_episode_by_number(ctx.item.id, 2, 8).title == "Harbor Lights"
    assert :counters.get(ctx.hits, 1) == 0, "the show must not be fetched"
    assert :counters.get(ctx.hits, 2) == 0, "a season that was not named must not be fetched"
    assert :counters.get(ctx.hits, 3) == 1

    assert [event] = events(ctx.item, "media_item.episode_titles_updated")
    assert event.actor_id == "airing_episode_refresh"
  end

  test "leaves the show row and the season throttle alone", ctx do
    updates_before = length(events(ctx.item, "media_item.updated"))
    stub_second_season(ctx, fn conn -> season_response(conn, ctx, "Harbor Lights") end)

    assert {:ok, []} = Media.refresh_seasons(ctx.item, [2], config: ctx.config)

    assert Media.get_media_item!(ctx.item.id).seasons_refreshed_at == nil
    assert length(events(ctx.item, "media_item.updated")) == updates_before
  end

  test "records nothing when no title changed", ctx do
    episode_fixture(%{
      media_item_id: ctx.item.id,
      season_number: 2,
      episode_number: 8,
      title: "Harbor Lights"
    })

    stub_second_season(ctx, fn conn -> season_response(conn, ctx, "Harbor Lights") end)

    assert {:ok, []} = Media.refresh_seasons(ctx.item, [2], config: ctx.config)
    assert events(ctx.item, "media_item.episode_titles_updated") == []
  end

  test "skips a season missing from stored metadata without fetching anything", ctx do
    assert {:ok, []} = Media.refresh_seasons(ctx.item, [5], config: ctx.config)

    assert :counters.get(ctx.hits, 1) == 0
    assert :counters.get(ctx.hits, 2) == 0
    assert :counters.get(ctx.hits, 3) == 0
  end

  test "reports a season that failed to fetch", ctx do
    stub_second_season(ctx, fn conn -> Plug.Conn.resp(conn, 404, "") end)

    assert {:error, {:failed_seasons, 1}} =
             Media.refresh_seasons(ctx.item, [2], config: ctx.config)
  end

  test "a show without a provider id is left to the weekly pass", ctx do
    item = media_item_fixture(%{type: "tv_show", title: "Nameless Harbor", year: 2025})

    assert {:error, :missing_provider_id} =
             Media.refresh_seasons(item, [1], config: ctx.config)
  end

  describe "a TMDB-sourced show" do
    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      tmdb_id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Signal Cove",
          year: 2025,
          tmdb_id: tmdb_id,
          metadata_source: :tmdb,
          metadata: %{
            seasons: [%{season_number: 1}]
          }
        })

      %{bypass: bypass, config: config, item: item, tmdb_id: tmdb_id}
    end

    test "re-reads a TMDB season and replaces a placeholder title", ctx do
      episode_fixture(%{
        media_item_id: ctx.item.id,
        season_number: 1,
        episode_number: 8,
        title: "Episode 8"
      })

      Bypass.stub(ctx.bypass, "GET", "/tmdb/tv/shows/#{ctx.tmdb_id}/1", fn conn ->
        json(conn, %{
          "season_number" => 1,
          "episodes" => [
            %{
              "season_number" => 1,
              "episode_number" => 8,
              "name" => "Harbor Lights",
              "air_date" => "2026-09-23"
            }
          ]
        })
      end)

      assert {:ok, [%{season: 1, episode: 8, old: "Episode 8", new: "Harbor Lights"}]} =
               Media.refresh_seasons(ctx.item, [1], config: ctx.config)

      assert Media.get_episode_by_number(ctx.item.id, 1, 8).title == "Harbor Lights"
      assert [_event] = events(ctx.item, "media_item.episode_titles_updated")
    end
  end

  defp stub_second_season(ctx, respond) do
    %{bypass: bypass, hits: hits, second_season: season_id} = ctx

    Bypass.stub(bypass, "GET", "/tvdb/seasons/#{season_id}/extended", fn conn ->
      :counters.add(hits, 3, 1)
      respond.(conn)
    end)
  end

  defp season_response(conn, ctx, name) do
    season_id = ctx.second_season

    json(conn, %{
      "data" => %{
        "id" => season_id,
        "number" => 2,
        "episodes" => [
          %{
            "id" => season_id + 8,
            "seasonNumber" => 2,
            "number" => 8,
            "name" => name,
            "aired" => "2026-09-23"
          }
        ]
      }
    })
  end

  defp events(item, type) do
    Events.list_events(type: type, resource_type: "media_item", resource_id: item.id)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
