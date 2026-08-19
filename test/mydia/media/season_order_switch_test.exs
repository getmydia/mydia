defmodule Mydia.Media.SeasonOrderSwitchTest do
  @moduledoc """
  Covers `SeasonOrder.switch/3` against a relay stub, with the emphasis on
  shows whose episode rows predate the `provider_episode_id` column.

  Every episode row written before that column existed holds NULL, and the
  only writer of it is a metadata refresh, which `should_skip_season_refresh?/1`
  throttles for up to 168 hours on an ended show. So a refusal here pointed the
  user at a remedy that silently does nothing — observed on production for
  Black Clover, 189 episodes, none of them tagged.
  """
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Media.SeasonOrder

  defp config(bypass) do
    %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 30_000}
    }
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  # One official season of 4, split into two DVD seasons of 2 — Black Clover's
  # shape in miniature.
  defp stub_series(bypass, tvdb_id, official_id, dvd_ids) do
    [dvd1, dvd2] = dvd_ids

    stub_seasons_list(bypass, tvdb_id, official_id, dvd_ids)

    stub_season(bypass, official_id, [
      %{"id" => 1001, "seasonNumber" => 1, "number" => 1},
      %{"id" => 1002, "seasonNumber" => 1, "number" => 2},
      %{"id" => 1003, "seasonNumber" => 1, "number" => 3},
      %{"id" => 1004, "seasonNumber" => 1, "number" => 4}
    ])

    stub_season(bypass, dvd1, [
      %{"id" => 1001, "seasonNumber" => 1, "number" => 1},
      %{"id" => 1002, "seasonNumber" => 1, "number" => 2}
    ])

    stub_season(bypass, dvd2, [
      %{"id" => 1003, "seasonNumber" => 2, "number" => 1},
      %{"id" => 1004, "seasonNumber" => 2, "number" => 2}
    ])
  end

  defp stub_seasons_list(bypass, tvdb_id, official_id, [dvd1, dvd2]) do
    Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
      json(conn, %{
        "data" => %{
          "seasons" => [
            %{"id" => official_id, "number" => 1, "type" => %{"type" => "official"}},
            %{"id" => dvd1, "number" => 1, "type" => %{"type" => "dvd"}},
            %{"id" => dvd2, "number" => 2, "type" => %{"type" => "dvd"}}
          ]
        }
      })
    end)
  end

  defp stub_season(bypass, season_id, episodes) do
    Bypass.stub(bypass, "GET", "/tvdb/seasons/#{season_id}/extended", fn conn ->
      json(conn, %{"data" => %{"episodes" => episodes}})
    end)
  end

  defp untagged_show(tvdb_id, count \\ 4) do
    show = media_item_fixture(%{type: "tv_show", title: "Untagged Show", tvdb_id: tvdb_id})

    for n <- 1..count do
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: n,
        provider_episode_id: nil
      })
    end

    show
  end

  defp coordinates(show) do
    show.id
    |> Media.list_episodes()
    |> Enum.map(&{&1.season_number, &1.episode_number})
    |> Enum.sort()
  end

  defp provider_ids(show) do
    show.id
    |> Media.list_episodes()
    |> Enum.map(& &1.provider_episode_id)
    |> Enum.sort()
  end

  # Unique per test so the 24h relay caches keyed on these ids cannot leak
  # between async tests.
  defp unique_ids do
    base = System.unique_integer([:positive])
    {base, base * 10, [base * 10 + 1, base * 10 + 2]}
  end

  describe "switch/3 with episodes that predate provider_episode_id" do
    test "backfills the ids from the current ordering and completes the switch" do
      bypass = Bypass.open()
      {tvdb_id, official_id, dvd_ids} = unique_ids()
      stub_series(bypass, tvdb_id, official_id, dvd_ids)

      show = untagged_show(tvdb_id)
      ids_before = show.id |> Media.list_episodes() |> Enum.map(& &1.id) |> Enum.sort()

      assert {:ok, 4} = SeasonOrder.switch(show, :dvd, config(bypass))

      assert coordinates(show) == [{1, 1}, {1, 2}, {2, 1}, {2, 2}]
      assert provider_ids(show) == ["1001", "1002", "1003", "1004"]

      # Same rows throughout: file links, watch history and monitored flags
      # ride on these ids.
      assert show.id |> Media.list_episodes() |> Enum.map(& &1.id) |> Enum.sort() == ids_before

      assert Repo.get!(MediaItem, show.id).season_order == :dvd
    end

    test "refuses when an episode sits where the current ordering has nothing" do
      bypass = Bypass.open()
      {tvdb_id, official_id, dvd_ids} = unique_ids()
      stub_series(bypass, tvdb_id, official_id, dvd_ids)

      show = untagged_show(tvdb_id)

      # A fifth episode at coordinates the official ordering never mentions:
      # nothing can tag it, so the switch must still refuse rather than move a
      # partially tagged show.
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 99,
        provider_episode_id: nil
      })

      assert {:error, :missing_provider_ids} = SeasonOrder.switch(show, :dvd, config(bypass))

      assert coordinates(show) == [{1, 1}, {1, 2}, {1, 3}, {1, 4}, {1, 99}]
      assert Repo.get!(MediaItem, show.id).season_order == nil
    end

    test "leaves ids that are already present alone" do
      bypass = Bypass.open()
      {tvdb_id, official_id, dvd_ids} = unique_ids()
      stub_series(bypass, tvdb_id, official_id, dvd_ids)

      show = media_item_fixture(%{type: "tv_show", title: "Half Tagged", tvdb_id: tvdb_id})

      for n <- 1..4 do
        episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: n,
          provider_episode_id: if(n <= 2, do: "#{1000 + n}", else: nil)
        })
      end

      assert {:ok, 4} = SeasonOrder.switch(show, :dvd, config(bypass))

      assert provider_ids(show) == ["1001", "1002", "1003", "1004"]
      assert coordinates(show) == [{1, 1}, {1, 2}, {2, 1}, {2, 2}]
    end

    test "refuses without writing when the current ordering cannot be fetched" do
      bypass = Bypass.open()
      {tvdb_id, official_id, dvd_ids} = unique_ids()
      [dvd1, dvd2] = dvd_ids

      stub_seasons_list(bypass, tvdb_id, official_id, dvd_ids)
      stub_season(bypass, dvd1, [%{"id" => 1001, "seasonNumber" => 1, "number" => 1}])
      stub_season(bypass, dvd2, [%{"id" => 1003, "seasonNumber" => 2, "number" => 1}])

      Bypass.stub(bypass, "GET", "/tvdb/seasons/#{official_id}/extended", fn conn ->
        Plug.Conn.resp(conn, 500, "")
      end)

      show = untagged_show(tvdb_id)

      assert {:error, _reason} = SeasonOrder.switch(show, :dvd, config(bypass))

      assert coordinates(show) == [{1, 1}, {1, 2}, {1, 3}, {1, 4}]
      assert provider_ids(show) == [nil, nil, nil, nil]
      assert Repo.get!(MediaItem, show.id).season_order == nil
    end

    # Black Clover's actual shape, verified against relay.mydia.dev for TVDB
    # 331753: the three orderings agree on all 170 numbered episodes and
    # disagree on specials — 19 official, 27 DVD, 0 absolute — and two of the
    # official specials are absent from the DVD ordering while the DVD ordering
    # hands their (0, 26) and (0, 27) coordinates to different episodes.
    # Counting specials therefore refused the switch outright, and remapping
    # them anyway would have collided.
    test "switches when the target ordering files specials differently" do
      bypass = Bypass.open()
      {tvdb_id, official_id, dvd_ids} = unique_ids()
      [dvd1, dvd2] = dvd_ids

      stub_seasons_list(bypass, tvdb_id, official_id, dvd_ids)

      stub_season(bypass, official_id, [
        %{"id" => 2001, "seasonNumber" => 0, "number" => 26},
        %{"id" => 2002, "seasonNumber" => 0, "number" => 27},
        %{"id" => 1001, "seasonNumber" => 1, "number" => 1},
        %{"id" => 1002, "seasonNumber" => 1, "number" => 2},
        %{"id" => 1003, "seasonNumber" => 1, "number" => 3},
        %{"id" => 1004, "seasonNumber" => 1, "number" => 4}
      ])

      # The DVD ordering knows nothing of 2001/2002 and reuses their
      # coordinates for two other specials entirely.
      stub_season(bypass, dvd1, [
        %{"id" => 3001, "seasonNumber" => 0, "number" => 26},
        %{"id" => 3002, "seasonNumber" => 0, "number" => 27},
        %{"id" => 1001, "seasonNumber" => 1, "number" => 1},
        %{"id" => 1002, "seasonNumber" => 1, "number" => 2}
      ])

      stub_season(bypass, dvd2, [
        %{"id" => 1003, "seasonNumber" => 2, "number" => 1},
        %{"id" => 1004, "seasonNumber" => 2, "number" => 2}
      ])

      show = media_item_fixture(%{type: "tv_show", title: "Has Specials", tvdb_id: tvdb_id})

      for {season, number} <- [{0, 26}, {0, 27}, {1, 1}, {1, 2}, {1, 3}, {1, 4}] do
        episode_fixture(%{
          media_item_id: show.id,
          season_number: season,
          episode_number: number,
          provider_episode_id: nil
        })
      end

      assert {:ok, 4} = SeasonOrder.switch(show, :dvd, config(bypass))

      # The numbered episodes moved; the specials stayed exactly where they
      # were rather than being renumbered onto another ordering's specials.
      assert coordinates(show) == [{0, 26}, {0, 27}, {1, 1}, {1, 2}, {2, 1}, {2, 2}]
      assert provider_ids(show) == ["1001", "1002", "1003", "1004", "2001", "2002"]
      assert Repo.get!(MediaItem, show.id).season_order == :dvd
    end

    test "switches to an ordering that lists no specials at all" do
      bypass = Bypass.open()
      {tvdb_id, official_id, _dvd_ids} = unique_ids()
      absolute_id = official_id + 5

      Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        json(conn, %{
          "data" => %{
            "seasons" => [
              %{"id" => official_id, "number" => 1, "type" => %{"type" => "official"}},
              %{"id" => absolute_id, "number" => 1, "type" => %{"type" => "absolute"}}
            ]
          }
        })
      end)

      stub_season(bypass, official_id, [
        %{"id" => 2001, "seasonNumber" => 0, "number" => 1},
        %{"id" => 1001, "seasonNumber" => 1, "number" => 1},
        %{"id" => 1002, "seasonNumber" => 2, "number" => 1}
      ])

      # Absolute ordering: no specials season at all, which used to refuse
      # every show that has one.
      stub_season(bypass, absolute_id, [
        %{"id" => 1001, "seasonNumber" => 1, "number" => 1},
        %{"id" => 1002, "seasonNumber" => 1, "number" => 2}
      ])

      show =
        media_item_fixture(%{type: "tv_show", title: "No Absolute Specials", tvdb_id: tvdb_id})

      for {season, number} <- [{0, 1}, {1, 1}, {2, 1}] do
        episode_fixture(%{
          media_item_id: show.id,
          season_number: season,
          episode_number: number,
          provider_episode_id: nil
        })
      end

      assert {:ok, 2} = SeasonOrder.switch(show, :absolute, config(bypass))

      assert coordinates(show) == [{0, 1}, {1, 1}, {1, 2}]
      assert Repo.get!(MediaItem, show.id).season_order == :absolute
    end

    # The importer creates episode rows from parsed filenames with no provider
    # id (`ImportGroups.link_local_member/2`), so a stray S00E99 file is enough
    # to produce a special that nothing can ever tag. Letting that block the
    # switch would put the show back behind the same unactionable message, for
    # good this time, over a row the switch does not touch.
    test "an untagged special does not block the switch" do
      bypass = Bypass.open()
      {tvdb_id, official_id, dvd_ids} = unique_ids()
      stub_series(bypass, tvdb_id, official_id, dvd_ids)

      show = untagged_show(tvdb_id)

      episode_fixture(%{
        media_item_id: show.id,
        season_number: 0,
        episode_number: 99,
        provider_episode_id: nil
      })

      assert {:ok, 4} = SeasonOrder.switch(show, :dvd, config(bypass))

      assert coordinates(show) == [{0, 99}, {1, 1}, {1, 2}, {2, 1}, {2, 2}]
      assert provider_ids(show) == [nil, "1001", "1002", "1003", "1004"]
      assert Repo.get!(MediaItem, show.id).season_order == :dvd
    end

    # Accounted for is not the same question as moved. The target ordering knows
    # this episode, it just files it as a special, and `mapping` holds only
    # numbered destinations — so judging completeness against `mapping` would
    # refuse the whole switch over a reclassification nobody asked about.
    test "an episode the target ordering files as a special is accounted for" do
      bypass = Bypass.open()
      {tvdb_id, official_id, dvd_ids} = unique_ids()
      [dvd1, dvd2] = dvd_ids

      stub_seasons_list(bypass, tvdb_id, official_id, dvd_ids)

      stub_season(bypass, official_id, [
        %{"id" => 1001, "seasonNumber" => 1, "number" => 1},
        %{"id" => 1002, "seasonNumber" => 1, "number" => 2},
        %{"id" => 1003, "seasonNumber" => 1, "number" => 3},
        %{"id" => 1004, "seasonNumber" => 1, "number" => 4}
      ])

      # 1004 is a numbered episode locally, and a special in the DVD ordering.
      stub_season(bypass, dvd1, [
        %{"id" => 1001, "seasonNumber" => 1, "number" => 1},
        %{"id" => 1002, "seasonNumber" => 1, "number" => 2},
        %{"id" => 1004, "seasonNumber" => 0, "number" => 3}
      ])

      stub_season(bypass, dvd2, [%{"id" => 1003, "seasonNumber" => 2, "number" => 1}])

      show = untagged_show(tvdb_id)

      assert {:ok, 3} = SeasonOrder.switch(show, :dvd, config(bypass))

      # It stays where it is rather than being renumbered into specials.
      assert coordinates(show) == [{1, 1}, {1, 2}, {1, 4}, {2, 1}]
      assert Repo.get!(MediaItem, show.id).season_order == :dvd
    end

    test "still refuses when the target ordering drops a numbered episode" do
      bypass = Bypass.open()
      {tvdb_id, official_id, dvd_ids} = unique_ids()
      [dvd1, dvd2] = dvd_ids

      stub_seasons_list(bypass, tvdb_id, official_id, dvd_ids)

      stub_season(bypass, official_id, [
        %{"id" => 1001, "seasonNumber" => 1, "number" => 1},
        %{"id" => 1002, "seasonNumber" => 1, "number" => 2},
        %{"id" => 1003, "seasonNumber" => 1, "number" => 3},
        %{"id" => 1004, "seasonNumber" => 1, "number" => 4}
      ])

      # 1004 is nowhere in the DVD ordering: a numbered episode really left
      # behind, which is the case the refusal exists for.
      stub_season(bypass, dvd1, [
        %{"id" => 1001, "seasonNumber" => 1, "number" => 1},
        %{"id" => 1002, "seasonNumber" => 1, "number" => 2}
      ])

      stub_season(bypass, dvd2, [%{"id" => 1003, "seasonNumber" => 2, "number" => 1}])

      show = untagged_show(tvdb_id)

      assert {:error, {:incomplete_ordering, 1}} = SeasonOrder.switch(show, :dvd, config(bypass))

      assert coordinates(show) == [{1, 1}, {1, 2}, {1, 3}, {1, 4}]
      assert Repo.get!(MediaItem, show.id).season_order == nil
    end

    test "a show already on the target ordering still confirms without any fetch" do
      bypass = Bypass.open()
      {tvdb_id, _official_id, _dvd_ids} = unique_ids()

      Bypass.down(bypass)

      show = untagged_show(tvdb_id)

      on_dvd =
        show
        |> Ecto.Changeset.change(season_order: :dvd)
        |> Repo.update!()

      assert {:ok, :confirmed} = SeasonOrder.switch(on_dvd, :dvd, config(bypass))
    end
  end
end
