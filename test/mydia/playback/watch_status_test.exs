defmodule Mydia.Playback.WatchStatusTest do
  use Mydia.DataCase, async: true

  alias Mydia.Media.Episode
  alias Mydia.Playback.Progress
  alias Mydia.Playback.WatchStatus
  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures
  alias Mydia.Playback

  defp episode(id, season_number), do: %Episode{id: id, season_number: season_number}

  defp watched(episode_id), do: {episode_id, %Progress{episode_id: episode_id, watched: true}}

  defp unwatched(episode_id), do: {episode_id, %Progress{episode_id: episode_id, watched: false}}

  describe "from_progress/1" do
    test "a missing progress row is unwatched with no percentage" do
      assert %WatchStatus{
               watched: false,
               percentage: nil,
               unwatched_episode_count: nil
             } = WatchStatus.from_progress(nil)
    end

    test "carries watched and completion_percentage across" do
      progress = %Progress{watched: true, completion_percentage: 99.5}

      assert %WatchStatus{watched: true, percentage: 99.5, unwatched_episode_count: nil} =
               WatchStatus.from_progress(progress)
    end

    test "a nil watched flag reads as false rather than nil" do
      assert %WatchStatus{watched: false} =
               WatchStatus.from_progress(%Progress{watched: nil, completion_percentage: 10.0})
    end
  end

  describe "from_episodes/3" do
    test "counts episodes with a file and no progress row" do
      episodes = [episode("e1", 1), episode("e2", 1)]
      files = MapSet.new(["e1", "e2"])

      assert %WatchStatus{watched: false, percentage: nil, unwatched_episode_count: 2} =
               WatchStatus.from_episodes(episodes, files, %{})
    end

    test "excludes episodes without a file" do
      episodes = [episode("e1", 1), episode("e2", 1)]
      files = MapSet.new(["e1"])

      assert %WatchStatus{unwatched_episode_count: 1} =
               WatchStatus.from_episodes(episodes, files, %{})
    end

    test "excludes season 0 specials even when they have files" do
      episodes = [episode("e1", 1), episode("s1", 0)]
      files = MapSet.new(["e1", "s1"])

      assert %WatchStatus{unwatched_episode_count: 1} =
               WatchStatus.from_episodes(episodes, files, %{})
    end

    test "a progress row with watched false still counts as unwatched" do
      episodes = [episode("e1", 1)]
      files = MapSet.new(["e1"])

      assert %WatchStatus{unwatched_episode_count: 1} =
               WatchStatus.from_episodes(episodes, files, Map.new([unwatched("e1")]))
    end

    test "a progress row with a nil watched flag counts as unwatched" do
      # `watched != true` rather than `watched == false` on purpose: the column
      # defaults to false, but a row that predates the default, or one built in
      # memory, can carry nil. Counting nil as watched would silently shrink
      # every badge it touched.
      episodes = [episode("e1", 1)]
      files = MapSet.new(["e1"])
      progress = %{"e1" => %Progress{episode_id: "e1", watched: nil}}

      assert %WatchStatus{watched: false, unwatched_episode_count: 1} =
               WatchStatus.from_episodes(episodes, files, progress)
    end

    test "every countable episode watched reads as watched with a zero count" do
      episodes = [episode("e1", 1), episode("e2", 1)]
      files = MapSet.new(["e1", "e2"])
      progress = Map.new([watched("e1"), watched("e2")])

      assert %WatchStatus{watched: true, unwatched_episode_count: 0} =
               WatchStatus.from_episodes(episodes, files, progress)
    end

    test "a show with no files at all is not watched, and draws nothing" do
      episodes = [episode("e1", 1)]

      assert %WatchStatus{watched: false, unwatched_episode_count: 0} =
               WatchStatus.from_episodes(episodes, MapSet.new(), %{})
    end

    test "a show whose only files are specials is not watched" do
      episodes = [episode("s1", 0)]

      assert %WatchStatus{watched: false, unwatched_episode_count: 0} =
               WatchStatus.from_episodes(episodes, MapSet.new(["s1"]), %{})
    end

    test "percentage is always nil for a rollup" do
      episodes = [episode("e1", 1)]

      assert %WatchStatus{percentage: nil} =
               WatchStatus.from_episodes(episodes, MapSet.new(["e1"]), %{})
    end
  end

  describe "load_shows/2" do
    setup do
      user = AccountsFixtures.user_fixture()
      show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Bundled"})

      e1 =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: 1
        })

      e2 =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 2,
          episode_number: 1
        })

      special =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 0,
          episode_number: 1
        })

      MediaFixtures.media_file_fixture(%{episode_id: e1.id})
      MediaFixtures.media_file_fixture(%{episode_id: e2.id})
      MediaFixtures.media_file_fixture(%{episode_id: special.id})

      %{user: user, show: show, e1: e1, e2: e2, special: special}
    end

    test "bundles every episode of the requested shows", ctx do
      bundles = WatchStatus.load_shows(ctx.user.id, [ctx.show.id])
      bundle = Map.fetch!(bundles, ctx.show.id)

      assert length(WatchStatus.episodes(bundle)) == 3
    end

    test "for_show/1 applies the counting rule across all seasons", ctx do
      bundles = WatchStatus.load_shows(ctx.user.id, [ctx.show.id])

      assert %WatchStatus{watched: false, unwatched_episode_count: 2} =
               WatchStatus.for_show(Map.fetch!(bundles, ctx.show.id))
    end

    test "for_season/2 scopes the count to one season", ctx do
      bundles = WatchStatus.load_shows(ctx.user.id, [ctx.show.id])
      bundle = Map.fetch!(bundles, ctx.show.id)

      assert %WatchStatus{unwatched_episode_count: 1} = WatchStatus.for_season(bundle, 1)
      assert %WatchStatus{unwatched_episode_count: 1} = WatchStatus.for_season(bundle, 2)
      assert %WatchStatus{unwatched_episode_count: 0} = WatchStatus.for_season(bundle, 0)
    end

    test "watching every non-special episode marks the show watched", ctx do
      for episode <- [ctx.e1, ctx.e2] do
        {:ok, _} =
          Playback.save_progress(
            ctx.user.id,
            [episode_id: episode.id],
            %{position_seconds: 100, duration_seconds: 100, watched: true}
          )
      end

      bundles = WatchStatus.load_shows(ctx.user.id, [ctx.show.id])

      assert %WatchStatus{watched: true, unwatched_episode_count: 0} =
               WatchStatus.for_show(Map.fetch!(bundles, ctx.show.id))
    end

    test "another user's progress never leaks into this user's count", ctx do
      other = AccountsFixtures.user_fixture()

      {:ok, _} =
        Playback.save_progress(
          other.id,
          [episode_id: ctx.e1.id],
          %{position_seconds: 100, duration_seconds: 100, watched: true}
        )

      bundles = WatchStatus.load_shows(ctx.user.id, [ctx.show.id])

      assert %WatchStatus{unwatched_episode_count: 2} =
               WatchStatus.for_show(Map.fetch!(bundles, ctx.show.id))
    end

    test "a nil user id yields counts with no progress applied", ctx do
      bundles = WatchStatus.load_shows(nil, [ctx.show.id])

      assert %WatchStatus{unwatched_episode_count: 2} =
               WatchStatus.for_show(Map.fetch!(bundles, ctx.show.id))
    end

    test "a show id with no episodes still gets a bundle", ctx do
      empty = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Empty"})
      bundles = WatchStatus.load_shows(ctx.user.id, [ctx.show.id, empty.id])

      assert %WatchStatus{watched: false, unwatched_episode_count: 0} =
               WatchStatus.for_show(Map.fetch!(bundles, empty.id))
    end

    test "for_show/1 tolerates a missing bundle", _ctx do
      assert %WatchStatus{watched: false, unwatched_episode_count: 0} =
               WatchStatus.for_show(nil)
    end
  end
end
