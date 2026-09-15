defmodule Mydia.Media.EpisodeTitleChangesTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Events
  alias Mydia.Media

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    tvdb_id = System.unique_integer([:positive])
    season_id = System.unique_integer([:positive])

    item =
      media_item_fixture(%{
        type: "tv_show",
        title: "Lantern Bay",
        year: 2025,
        tvdb_id: tvdb_id,
        metadata_source: :tvdb
      })

    %{bypass: bypass, config: config, item: item, tvdb_id: tvdb_id, season_id: season_id}
  end

  describe "refresh_episodes_for_tv_show/2 title changes" do
    test "a replaced placeholder title records one event for the show", ctx do
      stored_episode(ctx.item, 8, "TBA ")
      stub_show(ctx, [{8, "Harbor Lights"}])

      assert {:ok, _count} = Media.refresh_episodes_for_tv_show(ctx.item, config: ctx.config)

      assert Media.get_episode_by_number(ctx.item.id, 1, 8).title == "Harbor Lights"

      assert [event] = title_events(ctx.item)
      assert event.actor_id == "media_context"
      assert event.metadata["count"] == 1

      assert event.metadata["changes"] == [
               %{"season" => 1, "episode" => 8, "old" => "TBA ", "new" => "Harbor Lights"}
             ]
    end

    test "an unchanged title records nothing", ctx do
      stored_episode(ctx.item, 8, "Harbor Lights")
      stub_show(ctx, [{8, "Harbor Lights"}])

      assert {:ok, _count} = Media.refresh_episodes_for_tv_show(ctx.item, config: ctx.config)

      assert title_events(ctx.item) == []
    end

    test "a placeholder replaced by another placeholder records nothing", ctx do
      stored_episode(ctx.item, 8, "Episode 8")
      stub_show(ctx, [{8, "TBA "}])

      assert {:ok, _count} = Media.refresh_episodes_for_tv_show(ctx.item, config: ctx.config)

      assert Media.get_episode_by_number(ctx.item.id, 1, 8).title == "TBA "
      assert title_events(ctx.item) == []
    end

    test "a newly created episode is not a title change", ctx do
      stub_show(ctx, [{3, "Quiet Tide"}])

      assert {:ok, _count} = Media.refresh_episodes_for_tv_show(ctx.item, config: ctx.config)

      assert Media.get_episode_by_number(ctx.item.id, 1, 3).title == "Quiet Tide"
      assert title_events(ctx.item) == []
    end

    test "a title changed before a later episode fails is still recorded", ctx do
      stored_episode(ctx.item, 8, "TBA ")

      episode_fixture(%{
        media_item_id: ctx.item.id,
        season_number: 1,
        episode_number: 9,
        title: "Quiet Tide",
        provider_episode_id: "999999"
      })

      # 9 arrives with an id that is not "999999", so it cannot adopt the row
      # already tagged at those coordinates and falls through to create,
      # colliding with the unique index (stub_show/2 ids as
      # season_id * 100 + number, never "999999" here).
      stub_show(ctx, [{8, "Harbor Lights"}, {9, "Quiet Tide"}])

      assert {:ok, _count} = Media.refresh_episodes_for_tv_show(ctx.item, config: ctx.config)

      assert Media.get_episode_by_number(ctx.item.id, 1, 8).title == "Harbor Lights"

      assert [event] = title_events(ctx.item)
      assert event.metadata["count"] == 1

      assert event.metadata["changes"] == [
               %{"season" => 1, "episode" => 8, "old" => "TBA ", "new" => "Harbor Lights"}
             ]

      assert Media.get_media_item!(ctx.item.id).seasons_refreshed_at == nil
    end
  end

  defp stored_episode(item, number, title) do
    episode_fixture(%{
      media_item_id: item.id,
      season_number: 1,
      episode_number: number,
      title: title
    })
  end

  defp title_events(item) do
    Events.list_events(
      type: "media_item.episode_titles_updated",
      resource_type: "media_item",
      resource_id: item.id
    )
  end

  defp stub_show(ctx, episodes) do
    %{bypass: bypass, tvdb_id: tvdb_id, season_id: season_id} = ctx

    Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
      json(conn, %{
        "data" => %{
          "id" => tvdb_id,
          "name" => "Lantern Bay",
          "firstAired" => "2025-01-01",
          "status" => %{"name" => "Continuing"},
          "genres" => [],
          "seasons" => [
            %{
              "id" => season_id,
              "number" => 1,
              "name" => "Season 1",
              "type" => %{"type" => "official"}
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
          "episodes" =>
            Enum.map(episodes, fn {number, name} ->
              %{
                "id" => season_id * 100 + number,
                "seasonNumber" => 1,
                "number" => number,
                "name" => name,
                "aired" => "2026-09-23"
              }
            end)
        }
      })
    end)

    # A TVDB season stub with episodes also needs the per-episode
    # translations route (see test/README.md).
    Bypass.stub(bypass, "GET", "/tvdb/episodes/:episode_id/extended", fn conn ->
      json(conn, %{"data" => %{"translations" => %{}}})
    end)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
