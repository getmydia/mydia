defmodule MydiaWeb.Schema.ContinueWatchingTest do
  use MydiaWeb.ConnCase

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures
  alias Mydia.Playback

  @query """
  query ContinueWatching($first: Int) {
    continueWatching(first: $first) {
      id
      type
      title
      state
      showId
      showTitle
      seasonNumber
      episodeNumber
      progress {
        positionSeconds
        percentage
        watched
      }
      files {
        id
      }
    }
  }
  """

  setup do
    user = AccountsFixtures.user_fixture()
    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Test Show"})

    episodes =
      for n <- 1..3 do
        episode =
          MediaFixtures.episode_fixture(%{
            media_item_id: show.id,
            season_number: 1,
            episode_number: n
          })

        MediaFixtures.media_file_fixture(%{episode_id: episode.id})
        episode
      end

    %{user: user, show: show, episodes: episodes}
  end

  test "a finished episode surfaces its successor as a next item", ctx do
    [e1, e2, _e3] = ctx.episodes
    :changed = Playback.ensure_watched(ctx.user.id, episode_id: e1.id)

    assert {:ok, %{data: %{"continueWatching" => [item]}}} =
             run_query(@query, %{"first" => 10}, ctx.user)

    assert item["id"] == e2.id
    assert item["type"] == "EPISODE"
    assert item["state"] == "next"
    assert item["showId"] == ctx.show.id
    assert item["showTitle"] == "Test Show"
    assert item["seasonNumber"] == 1
    assert item["episodeNumber"] == 2
    assert item["progress"]["positionSeconds"] == 0
    assert item["progress"]["percentage"] == 0.0
    assert item["progress"]["watched"] == false
    assert length(item["files"]) == 1
  end

  test "an in-progress episode is a continue item carrying its real progress", ctx do
    [e1, _e2, _e3] = ctx.episodes

    {:ok, _} =
      Playback.save_progress(
        ctx.user.id,
        [episode_id: e1.id],
        %{position_seconds: 600, duration_seconds: 2400}
      )

    assert {:ok, %{data: %{"continueWatching" => [item]}}} =
             run_query(@query, %{"first" => 10}, ctx.user)

    assert item["id"] == e1.id
    assert item["state"] == "continue"
    assert item["progress"]["positionSeconds"] == 600
  end

  test "a never-started show returns nothing", ctx do
    assert {:ok, %{data: %{"continueWatching" => []}}} =
             run_query(@query, %{"first" => 10}, ctx.user)
  end

  test "an anonymous caller is denied by the fail-closed auth gate" do
    # continueWatching requires authentication (MydiaWeb.Schema.middleware/3,
    # MydiaWeb.Schema.Middleware.RequireAuth), so the nil-user branch in
    # continue_watching/3 is defense in depth but not reachable through the
    # schema. See auth_gating_test.exs.
    assert {:ok, %{data: %{"continueWatching" => nil}, errors: errors}} =
             run_query(@query, %{"first" => 10}, nil)

    assert Enum.any?(errors, &(&1.message =~ "Authentication required"))
  end

  defp run_query(query, variables, user) do
    context = if user, do: %{current_user: user}, else: %{}
    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: context)
  end
end
