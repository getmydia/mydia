defmodule Mydia.Media.RefreshSeasonOrderTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Media

  # TVDB returns every ordering of a series in one `seasons` list, and
  # `Relay.transform_tvdb_seasons/2` picks one of them. Nothing in `lib/` used
  # to supply an ordering, so the show's `season_order` column was inert end to
  # end: a show switched to :dvd kept refreshing against the official ordering
  # and its episodes drifted back to one giant season at the next refresh.
  #
  # The ordering is observable through which season ids the refresh then
  # fetches: each ordering's seasons carry their own TVDB season ids.
  describe "refresh_episodes_for_tv_show/2 season ordering" do
    setup do
      tvdb_id = System.unique_integer([:positive])
      official_id = System.unique_integer([:positive])
      dvd_one = System.unique_integer([:positive])
      dvd_two = System.unique_integer([:positive])

      bypass = Bypass.open()
      hits = start_supervised!({Agent, fn -> [] end})

      Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        json(conn, %{
          "data" => %{
            "id" => tvdb_id,
            "name" => "Ordered Show",
            "overview" => "x",
            "firstAired" => "2023-01-01",
            "status" => %{"name" => "Continuing"},
            "genres" => [],
            "seasons" => [
              season_stub(official_id, 1, "official"),
              season_stub(dvd_one, 1, "dvd"),
              season_stub(dvd_two, 2, "dvd")
            ]
          }
        })
      end)

      for {id, number} <- [{official_id, 1}, {dvd_one, 1}, {dvd_two, 2}] do
        Bypass.stub(bypass, "GET", "/tvdb/seasons/#{id}/extended", fn conn ->
          Agent.update(hits, &[id | &1])
          json(conn, %{"data" => %{"id" => id, "number" => number, "episodes" => []}})
        end)
      end

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{
        config: config,
        tvdb_id: tvdb_id,
        official_id: official_id,
        dvd_one: dvd_one,
        dvd_two: dvd_two,
        fetched: fn -> Agent.get(hits, & &1) end
      }
    end

    test "a show set to :dvd fetches the DVD ordering's seasons", ctx do
      item = show(ctx.tvdb_id, %{season_order: :dvd})

      assert {:ok, _count} = Media.refresh_episodes_for_tv_show(item, config: ctx.config)

      fetched = ctx.fetched.()

      assert ctx.dvd_one in fetched
      assert ctx.dvd_two in fetched
      refute ctx.official_id in fetched
    end

    # The counterpart matters as much as the test above: without it, an
    # implementation that always fetched every ordering's seasons would pass.
    test "a show with no recorded ordering fetches the official one", ctx do
      item = show(ctx.tvdb_id, %{})

      assert Repo.get!(Mydia.Media.MediaItem, item.id).season_order == nil
      assert {:ok, _count} = Media.refresh_episodes_for_tv_show(item, config: ctx.config)

      fetched = ctx.fetched.()

      assert ctx.official_id in fetched
      refute ctx.dvd_one in fetched
      refute ctx.dvd_two in fetched
    end

    test "an explicit :official ordering behaves like no ordering at all", ctx do
      item = show(ctx.tvdb_id, %{season_order: :official})

      assert {:ok, _count} = Media.refresh_episodes_for_tv_show(item, config: ctx.config)

      fetched = ctx.fetched.()

      assert ctx.official_id in fetched
      refute ctx.dvd_one in fetched
    end
  end

  defp show(tvdb_id, extra) do
    media_item_fixture(
      Map.merge(
        %{
          type: "tv_show",
          title: "Ordered Show",
          year: 2023,
          tvdb_id: tvdb_id,
          metadata_source: :tvdb
        },
        extra
      )
    )
  end

  defp season_stub(id, number, type) do
    %{
      "id" => id,
      "number" => number,
      "name" => "Season #{number}",
      "type" => %{"type" => type},
      "episodeCount" => 0
    }
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
