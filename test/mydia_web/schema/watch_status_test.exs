defmodule MydiaWeb.Schema.WatchStatusTest do
  use Mydia.DataCase, async: true

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures
  alias Mydia.Playback
  alias Mydia.Playback.WatchStatus
  alias MydiaWeb.Schema.Resolvers.MediaResolver

  defp run(query, user) do
    Absinthe.run(query, MydiaWeb.Schema, context: %{current_user: user})
  end

  defp show_with_two_episodes do
    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Counted"})

    episodes =
      for n <- 1..2 do
        episode =
          MediaFixtures.episode_fixture(%{
            media_item_id: show.id,
            season_number: 1,
            episode_number: n
          })

        MediaFixtures.media_file_fixture(%{episode_id: episode.id})
        episode
      end

    {show, episodes}
  end

  describe "TvShow.watchStatus" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "reports every playable episode as unwatched before anything is played", ctx do
      {show, _episodes} = show_with_two_episodes()

      query = """
      query { tvShow(id: "#{show.id}") { watchStatus { watched percentage unwatchedEpisodeCount } } }
      """

      assert {:ok, %{data: %{"tvShow" => %{"watchStatus" => status}}}} = run(query, ctx.user)

      assert status == %{
               "watched" => false,
               "percentage" => nil,
               "unwatchedEpisodeCount" => 2
             }
    end

    test "drops to watched with a zero count once all episodes are watched", ctx do
      {show, episodes} = show_with_two_episodes()

      for episode <- episodes do
        {:ok, _} =
          Playback.save_progress(
            ctx.user.id,
            [episode_id: episode.id],
            %{position_seconds: 100, duration_seconds: 100, watched: true}
          )
      end

      query = """
      query { tvShow(id: "#{show.id}") { watchStatus { watched unwatchedEpisodeCount } } }
      """

      assert {:ok, %{data: %{"tvShow" => %{"watchStatus" => status}}}} = run(query, ctx.user)
      assert status == %{"watched" => true, "unwatchedEpisodeCount" => 0}
    end

    test "resolves to null without a current user" do
      {show, _episodes} = show_with_two_episodes()

      # Root queries are wrapped in RequireAuth, so `tvShow` never reaches
      # nested resolvers when current_user is nil. Call the resolver directly
      # to cover the unauthenticated branch the field itself implements.
      assert {:ok, nil} =
               MydiaWeb.Schema.Resolvers.MediaResolver.resolve_show_watch_status(
                 %{id: show.id},
                 %{},
                 %{context: %{current_user: nil}}
               )
    end
  end

  describe "Season.watchStatus" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "scopes the count to the season", ctx do
      show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Seasoned"})

      for {season, number} <- [{1, 1}, {1, 2}, {2, 1}] do
        episode =
          MediaFixtures.episode_fixture(%{
            media_item_id: show.id,
            season_number: season,
            episode_number: number
          })

        MediaFixtures.media_file_fixture(%{episode_id: episode.id})
      end

      query = """
      query { tvShow(id: "#{show.id}") { seasons { seasonNumber watchStatus { unwatchedEpisodeCount } } } }
      """

      assert {:ok, %{data: %{"tvShow" => %{"seasons" => seasons}}}} = run(query, ctx.user)

      by_number = Map.new(seasons, &{&1["seasonNumber"], &1["watchStatus"]})
      assert by_number[1] == %{"unwatchedEpisodeCount" => 2}
      assert by_number[2] == %{"unwatchedEpisodeCount" => 1}
    end
  end

  describe "Movie.watchStatus" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "carries the movie's own progress", ctx do
      movie = MediaFixtures.media_item_fixture(%{type: "movie", title: "Solo"})

      {:ok, _} =
        Playback.save_progress(
          ctx.user.id,
          [media_item_id: movie.id],
          %{position_seconds: 30, duration_seconds: 100}
        )

      query = """
      query { movie(id: "#{movie.id}") { watchStatus { watched unwatchedEpisodeCount } } }
      """

      assert {:ok, %{data: %{"movie" => %{"watchStatus" => status}}}} = run(query, ctx.user)
      assert status == %{"watched" => false, "unwatchedEpisodeCount" => nil}
    end

    test "an unplayed movie is unwatched rather than null", ctx do
      movie = MediaFixtures.media_item_fixture(%{type: "movie", title: "Untouched"})

      query = """
      query { movie(id: "#{movie.id}") { watchStatus { watched percentage } } }
      """

      assert {:ok, %{data: %{"movie" => %{"watchStatus" => status}}}} = run(query, ctx.user)
      assert status == %{"watched" => false, "percentage" => nil}
    end
  end

  describe "Episode.watchStatus" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "carries the episode's own progress", ctx do
      {_show, [episode | _]} = show_with_two_episodes()

      {:ok, _} =
        Playback.save_progress(
          ctx.user.id,
          [episode_id: episode.id],
          %{position_seconds: 100, duration_seconds: 100, watched: true}
        )

      assert {:ok, %WatchStatus{watched: true, unwatched_episode_count: nil}} =
               MediaResolver.resolve_episode_watch_status(
                 %{id: episode.id},
                 %{},
                 %{context: %{current_user: ctx.user}}
               )
    end

    test "resolves to nil without a current user" do
      {_show, [episode | _]} = show_with_two_episodes()

      assert {:ok, nil} =
               MediaResolver.resolve_episode_watch_status(
                 %{id: episode.id},
                 %{},
                 %{context: %{}}
               )
    end
  end

  describe "RecentlyAddedItem.watchStatus" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "rolls a show up through the batch path", ctx do
      # RecentlyAddedItem is the type behind Favorites, Recently Added, and
      # Unwatched, and its resolver is the only polymorphic one here. The show
      # branch has to go through a real query rather than a direct call,
      # because `batch/3` returns middleware rather than a value and only
      # Absinthe resolves it.
      {show, _episodes} = show_with_two_episodes()

      query = """
      query { recentlyAdded(first: 20) { id watchStatus { watched unwatchedEpisodeCount } } }
      """

      assert {:ok, %{data: %{"recentlyAdded" => items}}} = run(query, ctx.user)

      item = Enum.find(items, &(&1["id"] == show.id))
      refute is_nil(item), "expected the seeded show on the recently-added list"

      assert item["watchStatus"] == %{"watched" => false, "unwatchedEpisodeCount" => 2}
    end

    test "takes the movie branch for a movie", ctx do
      movie = MediaFixtures.media_item_fixture(%{type: "movie", title: "Recently Added Movie"})

      assert {:ok, %WatchStatus{watched: false, unwatched_episode_count: nil}} =
               MediaResolver.resolve_recently_added_watch_status(
                 %{id: movie.id, type: :movie},
                 %{},
                 %{context: %{current_user: ctx.user}}
               )
    end

    test "resolves to nil without a current user" do
      assert {:ok, nil} =
               MediaResolver.resolve_recently_added_watch_status(
                 %{id: "anything", type: :tv_show},
                 %{},
                 %{context: %{}}
               )
    end
  end
end
