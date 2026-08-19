defmodule Mydia.Media.RefreshSeasonOrderTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Media
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem

  # TVDB returns every ordering of a series in one `seasons` list, and
  # `Relay.transform_tvdb_seasons/2` picks one of them. Nothing in `lib/` used
  # to supply an ordering, so the show's `season_order` column was inert end to
  # end: a show switched to :dvd kept refreshing against the official ordering
  # and its episodes drifted back to one giant season at the next refresh.
  #
  # The ordering is observable through which season ids the refresh then
  # fetches: each ordering's seasons carry their own TVDB season ids.
  describe "refresh_episodes_for_tv_show/2 season ordering" do
    setup :ordering_stubs

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

  # The throttle keeps the weekly sweep off the relay, which is right for a
  # sweep and wrong for a person: it also silently declined the episode half of
  # a refresh someone clicked for, for 24 hours or 168 once the show ended,
  # while the item row still updated and the flash still said it worked. That
  # is what made "refresh this show's metadata, then try again" an instruction
  # nobody could act on.
  #
  # Observable the same way as the ordering tests: whether any season was
  # fetched at all.
  describe "refresh_episodes_for_tv_show/2 season refresh throttle" do
    setup :ordering_stubs

    test "skips the episode fetch for a show refreshed moments ago", ctx do
      item = recently_refreshed(ctx.tvdb_id)

      assert {:ok, _count} = Media.refresh_episodes_for_tv_show(item, config: ctx.config)

      assert ctx.fetched.() == []
    end

    test "force: true fetches anyway", ctx do
      item = recently_refreshed(ctx.tvdb_id)

      assert {:ok, _count} =
               Media.refresh_episodes_for_tv_show(item, config: ctx.config, force: true)

      assert ctx.official_id in ctx.fetched.()
    end

    test "Refresh.run/2 threads force through to the episode leg", ctx do
      item = recently_refreshed(ctx.tvdb_id)

      assert {:ok, _updated} = Media.Refresh.run(item, config: ctx.config, force: true)

      assert ctx.official_id in ctx.fetched.()
    end

    test "Refresh.run/2 without force leaves the throttle in place", ctx do
      item = recently_refreshed(ctx.tvdb_id)

      assert {:ok, _updated} = Media.Refresh.run(item, config: ctx.config)

      assert ctx.fetched.() == []
    end
  end

  # A refresh reads the show's ordering once, fetches every season under it,
  # then writes. A `SeasonOrder.switch/3` committing in between used to leave
  # the refresh writing the old ordering's coordinates back over the freshly
  # remapped rows, mixing two orderings under a `season_order` column that
  # claims one.
  describe "refresh_episodes_for_tv_show/2 racing an ordering switch" do
    setup :ordering_stubs

    test "declines to write season data fetched under an ordering the show has left", ctx do
      item = show(ctx.tvdb_id, %{})

      # The switch commits after this pass loaded `item`: the row moves to
      # :dvd while the struct in hand still describes the official ordering.
      Repo.update_all(
        from(m in MediaItem, where: m.id == ^item.id),
        set: [season_order: :dvd]
      )

      assert {:ok, 0} = Media.refresh_episodes_for_tv_show(item, config: ctx.config)

      # The fetch did happen, so it is the freshness check that declined the
      # write and not the throttle quietly skipping the whole pass.
      assert ctx.official_id in ctx.fetched.()
      assert episode_count(item) == 0

      # Unstamped, so the next refresh re-fetches under :dvd rather than
      # waiting out the throttle in a half-written state.
      assert is_nil(Repo.get!(MediaItem, item.id).seasons_refreshed_at)
    end

    # `provider_switch_attrs/3` also clears `season_order`, so comparing only
    # that column reads nil == nil and calls a provider switch "unchanged" --
    # for the overwhelmingly common show that was already nil. The payload in
    # hand belongs to a series this no longer is, ids and all.
    test "declines to write season data fetched for a provider the show has left", ctx do
      item = show(ctx.tvdb_id, %{})

      Repo.update_all(
        from(m in MediaItem, where: m.id == ^item.id),
        set: [metadata_source: :tmdb, tvdb_id: nil, tmdb_id: 4242, season_order: nil]
      )

      assert {:ok, 0} = Media.refresh_episodes_for_tv_show(item, config: ctx.config)

      assert episode_count(item) == 0
      assert is_nil(Repo.get!(MediaItem, item.id).seasons_refreshed_at)
    end

    test "writes and stamps when no switch intervenes", ctx do
      item = show(ctx.tvdb_id, %{})

      assert {:ok, 1} = Media.refresh_episodes_for_tv_show(item, config: ctx.config)

      assert episode_count(item) == 1
      refute is_nil(Repo.get!(MediaItem, item.id).seasons_refreshed_at)
    end
  end

  # `should_skip_season_refresh?/1` reads the struct it is handed, not the row,
  # so the stamp has to be reloaded or every one of these tests passes for the
  # wrong reason.
  defp recently_refreshed(tvdb_id) do
    item = show(tvdb_id, %{})
    Media.stamp_seasons_refreshed(item)
    reloaded = Repo.get!(Mydia.Media.MediaItem, item.id)

    refute is_nil(reloaded.seasons_refreshed_at)

    reloaded
  end

  defp episode_count(item) do
    Repo.aggregate(from(e in Episode, where: e.media_item_id == ^item.id), :count)
  end

  defp ordering_stubs(_context) do
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

    # A TVDB season payload carries no per-episode translations, so the provider
    # fetches each episode on its own. Unstubbed, every season fetch above turns
    # into three retried 500s and Bypass fails the test on the unexpected call.
    Bypass.stub(bypass, "GET", "/tvdb/episodes/:episode_id/extended", fn conn ->
      json(conn, %{"data" => %{"translations" => %{}}})
    end)

    for {id, number} <- [{official_id, 1}, {dvd_one, 1}, {dvd_two, 2}] do
      Bypass.stub(bypass, "GET", "/tvdb/seasons/#{id}/extended", fn conn ->
        Agent.update(hits, &[id | &1])

        json(conn, %{
          "data" => %{
            "id" => id,
            "number" => number,
            "episodes" => [
              %{
                "id" => id * 10 + 1,
                "seasonNumber" => number,
                "number" => 1,
                "name" => "Episode 1",
                "aired" => "2023-01-01"
              }
            ]
          }
        })
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
