defmodule Mydia.Jobs.MetadataRefreshEpisodesTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

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
        json(conn, %{
          "data" => %{
            "id" => tvdb_id,
            "name" => "Late Still Show",
            "overview" => "x",
            "first_air_date" => "2023-01-01",
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

      refreshed = Media.get_episode_by_number(item.id, 1, 1)

      assert refreshed.metadata.still_path == still,
             "the scheduled pass must re-read episode metadata, " <>
               "got: #{inspect(refreshed.metadata.still_path)}"

      assert refreshed.metadata.overview == "Published once the episode aired."
      assert refreshed.metadata.runtime == 52
    end
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
