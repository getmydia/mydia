defmodule Mydia.Jobs.MetadataRefreshEpisodesTest do
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Jobs.MetadataRefresh
  alias Mydia.Media

  # REGRESSION: the scheduled metadata pass called Refresh.run/2 with
  # `fetch_episodes: false`, and it is the only recurring job that re-reads
  # provider data. Episode rows were therefore written once at import and never
  # again, so anything a provider publishes once an episode airs — the
  # screencap, overview and runtime — could never land. Observed on the Silo
  # library: the show row refreshed weekly while its episodes stayed frozen at
  # their import date, leaving the two most recently aired episodes without
  # thumbnails even though TVDB had published them.
  describe "scheduled pass refreshes episodes" do
    test "an already-imported episode picks up a still published after import" do
      tvdb_id = System.unique_integer([:positive])
      season_id = System.unique_integer([:positive])
      episode_id = System.unique_integer([:positive])
      still = "https://artworks.thetvdb.com/banners/v4/episode/#{episode_id}/screencap/abc.jpg"

      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        # TVDB input shape, not the TMDB-like shape the relay transforms it
        # into: "firstAired" and a nested "status", per
        # transform_tvdb_to_tmdb_format/3. Sending "first_air_date" here would
        # leave first_air_date nil and quietly overwrite the show's year.
        json(conn, %{
          "data" => %{
            "id" => tvdb_id,
            "name" => "Late Still Show",
            "overview" => "x",
            "firstAired" => "2023-01-01",
            "status" => %{"name" => "Continuing"},
            "genres" => [],
            "seasons" => [
              %{
                "id" => season_id,
                "number" => 1,
                "name" => "Season 1",
                "type" => %{"type" => "official"},
                "episodeCount" => 1
              }
            ]
          }
        })
      end)

      Bypass.stub(bypass, "GET", "/tvdb/seasons/#{season_id}/extended", fn conn ->
        json(conn, %{
          "data" => %{
            "id" => season_id,
            "number" => 1,
            "name" => "Season 1",
            "episodes" => [
              %{
                "id" => episode_id,
                "seasonNumber" => 1,
                "number" => 1,
                "name" => "The Drive",
                "overview" => "Published once the episode aired.",
                "aired" => "2023-01-08",
                "runtime" => 52,
                "image" => still
              }
            ]
          }
        })
      end)

      Bypass.stub(bypass, "GET", "/tvdb/episodes/#{episode_id}/extended", fn conn ->
        json(conn, %{"data" => %{"id" => episode_id, "translations" => %{}}})
      end)

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Late Still Show",
          year: 2023,
          tvdb_id: tvdb_id,
          metadata_source: :tvdb
        })

      # The row as it looks when imported before the episode aired: the
      # provider had a title and air date but no screencap yet.
      episode_fixture(%{
        media_item_id: item.id,
        season_number: 1,
        episode_number: 1,
        title: "The Drive",
        metadata: %{
          season_number: 1,
          episode_number: 1,
          name: "The Drive",
          still_path: nil,
          overview: nil,
          runtime: nil
        }
      })

      assert {:ok, _updated} = MetadataRefresh.refresh_one(item, config: config)

      refreshed = Media.get_episode_by_number(Scope.unrestricted(), item.id, 1, 1)

      assert refreshed.metadata.still_path == still,
             "the scheduled pass must re-read episode metadata, " <>
               "got: #{inspect(refreshed.metadata.still_path)}"

      assert refreshed.metadata.overview == "Published once the episode aired."
      assert refreshed.metadata.runtime == 52

      # The show row must survive the pass intact: a mis-shaped provider payload
      # shows up here as the year being nulled out.
      assert Media.get_media_item!(Scope.unrestricted(), item.id).year == 2023
    end
  end

  # REGRESSION: should_skip_season_refresh?/1 is the only thing bounding how
  # often the pass above re-reads a show, and it was dead in two further ways
  # beyond never being called.
  describe "season refresh throttle" do
    test "stamp_seasons_refreshed/1 persists the timestamp" do
      item = media_item_fixture(%{type: "tv_show", title: "Stamped Show", year: 2023})

      assert Media.get_media_item!(Scope.unrestricted(), item.id).seasons_refreshed_at == nil

      Media.stamp_seasons_refreshed(item)

      assert %DateTime{} =
               Media.get_media_item!(Scope.unrestricted(), item.id).seasons_refreshed_at
    end

    test "the timestamp is not mass-assignable through update_media_item/3" do
      item = media_item_fixture(%{type: "tv_show", title: "Unstamped Show", year: 2023})
      stamp = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, _} =
               Media.update_media_item(Scope.unrestricted(), item, %{seasons_refreshed_at: stamp})

      # The throttle field is owned by the refresh machinery. Writing it through
      # the generic changeset must stay a no-op, so callers cannot extend their
      # own throttle window by passing it in attrs.
      assert Media.get_media_item!(Scope.unrestricted(), item.id).seasons_refreshed_at == nil
    end

    test "an ended show is throttled on the completed-show threshold" do
      bypass = Bypass.open()
      hits = :atomics.new(1, signed: false)

      Bypass.stub(bypass, "GET", "/tvdb/series/:id/extended", fn conn ->
        :atomics.add(hits, 1, 1)
        json(conn, %{"data" => %{}})
      end)

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Finished Show",
          year: 2010,
          tvdb_id: System.unique_integer([:positive]),
          metadata_source: :tvdb,
          metadata: %{status: "Ended"}
        })

      # 48h ago: past the 24h ongoing threshold, well inside the 168h completed
      # one. The ended branch matched a string key against an atom-keyed
      # %MediaMetadata{}, so is_completed was always false and this show was
      # throttled as if it were still airing — i.e. refreshed anyway.
      stamp = DateTime.utc_now() |> DateTime.add(-48, :hour) |> DateTime.truncate(:second)

      Mydia.Repo.update_all(
        from(m in Mydia.Media.MediaItem, where: m.id == ^item.id),
        set: [seasons_refreshed_at: stamp]
      )

      item = Media.get_media_item!(Scope.unrestricted(), item.id)

      episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})

      assert {:ok, 1} = Media.refresh_episodes_for_tv_show(item, config: config)

      assert :atomics.get(hits, 1) == 0,
             "an ended show inside its threshold must not be refetched"
    end

    test "a failed season leaves the timestamp unstamped so the retry is not throttled" do
      tvdb_id = System.unique_integer([:positive])
      good_season = System.unique_integer([:positive])
      bad_season = System.unique_integer([:positive])

      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        json(conn, %{
          "data" => %{
            "id" => tvdb_id,
            "name" => "Half Broken Show",
            "firstAired" => "2023-01-01",
            "status" => %{"name" => "Continuing"},
            "genres" => [],
            "seasons" => [
              season_stub(good_season, 1),
              season_stub(bad_season, 2)
            ]
          }
        })
      end)

      Bypass.stub(bypass, "GET", "/tvdb/seasons/#{good_season}/extended", fn conn ->
        json(conn, %{"data" => %{"id" => good_season, "number" => 1, "episodes" => []}})
      end)

      # Season 2 is unavailable this pass.
      Bypass.stub(bypass, "GET", "/tvdb/seasons/#{bad_season}/extended", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Half Broken Show",
          year: 2023,
          tvdb_id: tvdb_id,
          metadata_source: :tvdb
        })

      assert {:ok, _count} = Media.refresh_episodes_for_tv_show(item, config: config)

      # Stamping here would throttle the next pass and hide the season that
      # failed until the threshold expired.
      assert Media.get_media_item!(Scope.unrestricted(), item.id).seasons_refreshed_at == nil
    end

    test "a partial season selection does not stamp a full-refresh timestamp" do
      tvdb_id = System.unique_integer([:positive])
      season_one = System.unique_integer([:positive])
      season_two = System.unique_integer([:positive])

      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        json(conn, %{
          "data" => %{
            "id" => tvdb_id,
            "name" => "Partial Show",
            "firstAired" => "2023-01-01",
            "status" => %{"name" => "Continuing"},
            "genres" => [],
            "seasons" => [season_stub(season_one, 1), season_stub(season_two, 2)]
          }
        })
      end)

      for {id, number} <- [{season_one, 1}, {season_two, 2}] do
        Bypass.stub(bypass, "GET", "/tvdb/seasons/#{id}/extended", fn conn ->
          json(conn, %{"data" => %{"id" => id, "number" => number, "episodes" => []}})
        end)
      end

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Partial Show",
          year: 2023,
          tvdb_id: tvdb_id,
          metadata_source: :tvdb
        })

      # "latest" is reachable from the add-media UI. It fetches one season, so
      # stamping would throttle the next "all" pass over a show whose earlier
      # seasons were never refreshed.
      assert {:ok, _} =
               Media.refresh_episodes_for_tv_show(item,
                 config: config,
                 season_monitoring: "latest"
               )

      assert Media.get_media_item!(Scope.unrestricted(), item.id).seasons_refreshed_at == nil
    end
  end

  defp season_stub(id, number) do
    %{
      "id" => id,
      "number" => number,
      "name" => "Season #{number}",
      "type" => %{"type" => "official"},
      "episodeCount" => 0
    }
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
