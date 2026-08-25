defmodule MydiaWeb.Schema.NextUpTest do
  use MydiaWeb.ConnCase

  alias Mydia.Accounts.Scope
  alias Mydia.Playback
  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures

  @next_up_query """
  query TvShowNextUp($id: ID!) {
    tvShow(id: $id) {
      id
      nextUp {
        progressState
        episode {
          id
          seasonNumber
          episodeNumber
        }
      }
    }
  }
  """

  setup do
    user = AccountsFixtures.user_fixture()
    show = MediaFixtures.media_item_fixture(%{type: "tv_show"})

    episodes =
      for n <- 1..3 do
        episode =
          MediaFixtures.episode_fixture(%{
            media_item_id: show.id,
            season_number: 1,
            episode_number: n
          })

        # get_next_episode/2 only considers episodes with a non-trashed file.
        MediaFixtures.media_file_fixture(%{episode_id: episode.id})
        episode
      end

    %{user: user, show: show, episodes: episodes}
  end

  describe "tvShow.nextUp" do
    test "returns start and the first episode when nothing is watched", ctx do
      [e1 | _] = ctx.episodes

      assert {:ok, %{data: %{"tvShow" => %{"nextUp" => next_up}}}} =
               run_query(@next_up_query, %{"id" => ctx.show.id}, ctx.user)

      assert next_up["progressState"] == "start"
      assert next_up["episode"]["id"] == e1.id
    end

    test "returns continue and the in-progress episode", ctx do
      [e1 | _] = ctx.episodes

      {:ok, _} =
        Playback.save_progress(
          ctx.user.id,
          [episode_id: e1.id],
          %{position_seconds: 300, duration_seconds: 2400}
        )

      assert {:ok, %{data: %{"tvShow" => %{"nextUp" => next_up}}}} =
               run_query(@next_up_query, %{"id" => ctx.show.id}, ctx.user)

      assert next_up["progressState"] == "continue"
      assert next_up["episode"]["id"] == e1.id
    end

    test "returns next and the following episode once one is watched", ctx do
      [e1, e2 | _] = ctx.episodes
      :changed = Playback.ensure_watched(ctx.user.id, episode_id: e1.id)

      assert {:ok, %{data: %{"tvShow" => %{"nextUp" => next_up}}}} =
               run_query(@next_up_query, %{"id" => ctx.show.id}, ctx.user)

      assert next_up["progressState"] == "next"
      assert next_up["episode"]["id"] == e2.id
    end

    test "returns null when every episode is watched", ctx do
      Enum.each(
        ctx.episodes,
        &(:changed = Playback.ensure_watched(ctx.user.id, episode_id: &1.id))
      )

      assert {:ok, %{data: %{"tvShow" => %{"nextUp" => nil}}}} =
               run_query(@next_up_query, %{"id" => ctx.show.id}, ctx.user)
    end

    test "returns null for a show with no episodes", ctx do
      empty = MediaFixtures.media_item_fixture(%{type: "tv_show"})

      assert {:ok, %{data: %{"tvShow" => %{"nextUp" => nil}}}} =
               run_query(@next_up_query, %{"id" => empty.id}, ctx.user)
    end

    test "returns null when every episode's only file is trashed", ctx do
      # get_next_episode/2 preloads media_files with `where is_nil(trashed_at)`
      # and then drops episodes whose list came back empty, so a show whose
      # files are all trashed is indistinguishable from one with no files.
      show = MediaFixtures.media_item_fixture(%{type: "tv_show"})

      episode =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: 1
        })

      MediaFixtures.media_file_fixture(%{
        episode_id: episode.id,
        trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      assert {:ok, %{data: %{"tvShow" => %{"nextUp" => nil}}}} =
               run_query(@next_up_query, %{"id" => show.id}, ctx.user)
    end

    test "anonymous callers are denied by the fail-closed auth gate", ctx do
      # The tvShow root field requires authentication (MydiaWeb.Schema.middleware/3,
      # MydiaWeb.Schema.Middleware.RequireAuth), so the anonymous branch in
      # resolve_next_up/3 mirrors resolve_next_episode/3 for defense in depth but
      # is not reachable through the schema. See auth_gating_test.exs.
      assert {:ok, %{data: %{"tvShow" => nil}, errors: errors}} =
               run_query(@next_up_query, %{"id" => ctx.show.id})

      assert Enum.any?(errors, &(&1.message =~ "Authentication required"))
    end

    test "nextEpisode still resolves, so older players keep working", ctx do
      query = """
      query Legacy($id: ID!) {
        tvShow(id: $id) { nextEpisode { id } }
      }
      """

      assert {:ok, %{data: %{"tvShow" => %{"nextEpisode" => %{"id" => _}}}}} =
               run_query(query, %{"id" => ctx.show.id}, ctx.user)
    end
  end

  describe "continueWatching.files" do
    @continue_watching_query """
    query ContinueWatching {
      continueWatching(first: 10) {
        id
        type
        showId
        files { id }
      }
    }
    """

    test "an in-progress episode exposes its files and showId", ctx do
      [e1 | _] = ctx.episodes

      {:ok, _} =
        Playback.save_progress(
          ctx.user.id,
          [episode_id: e1.id],
          %{position_seconds: 300, duration_seconds: 2400}
        )

      assert {:ok, %{data: %{"continueWatching" => items}}} =
               run_query(@continue_watching_query, %{}, ctx.user)

      item = Enum.find(items, &(&1["id"] == e1.id))
      refute item == nil
      assert item["showId"] == ctx.show.id
      refute Enum.empty?(item["files"])
    end

    test "an in-progress movie exposes its files", ctx do
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})
      MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

      {:ok, _} =
        Playback.save_progress(
          ctx.user.id,
          [media_item_id: movie.id],
          %{position_seconds: 300, duration_seconds: 7200}
        )

      assert {:ok, %{data: %{"continueWatching" => items}}} =
               run_query(@continue_watching_query, %{}, ctx.user)

      item = Enum.find(items, &(&1["id"] == movie.id))
      refute item == nil
      refute Enum.empty?(item["files"])
    end
  end

  defp run_query(query, variables, user \\ nil) do
    context =
      if user, do: %{current_user: user, current_scope: Scope.for_user(user)}, else: %{}

    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: context)
  end
end
