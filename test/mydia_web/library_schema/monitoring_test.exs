defmodule MydiaWeb.LibrarySchema.MonitoringTest do
  use MydiaWeb.ConnCase

  alias Mydia.LibraryApi.Principal
  alias Mydia.Media

  @admin %Principal{role: "admin", source: :env}

  defp run(document, variables) do
    Absinthe.run(document, MydiaWeb.LibrarySchema,
      variables: variables,
      context: %{principal: @admin}
    )
  end

  @set_item """
  mutation Set($id: ID!, $monitored: Boolean!) {
    setMediaItemMonitored(id: $id, monitored: $monitored) {
      mediaItem { id monitored }
      userErrors { field code message }
    }
  }
  """

  describe "setMediaItemMonitored" do
    test "turns monitoring off and returns the reloaded item" do
      item = insert(:media_item, monitored: true)

      assert {:ok, %{data: %{"setMediaItemMonitored" => payload}}} =
               run(@set_item, %{"id" => item.id, "monitored" => false})

      assert payload["userErrors"] == []
      assert payload["mediaItem"] == %{"id" => item.id, "monitored" => false}
      refute Media.get_media_item!(item.id).monitored
    end

    test "an id that names nothing is NOT_FOUND on id" do
      assert {:ok, %{data: %{"setMediaItemMonitored" => payload}}} =
               run(@set_item, %{"id" => Ecto.UUID.generate(), "monitored" => true})

      assert payload["mediaItem"] == nil
      assert [%{"code" => "NOT_FOUND", "field" => ["id"]}] = payload["userErrors"]
    end

    test "a malformed id is INVALID_INPUT on id" do
      assert {:ok, %{data: %{"setMediaItemMonitored" => payload}}} =
               run(@set_item, %{"id" => "not-a-uuid", "monitored" => true})

      assert [%{"code" => "INVALID_INPUT", "field" => ["id"]}] = payload["userErrors"]
    end
  end

  @set_season """
  mutation Season($id: ID!, $season: Int!, $monitored: Boolean!) {
    setSeasonMonitored(mediaItemId: $id, season: $season, monitored: $monitored) {
      mediaItem { id episodes { seasonNumber episodeNumber monitored } }
      userErrors { field code }
    }
  }
  """

  describe "setSeasonMonitored" do
    test "changes every episode in the season and no other" do
      show = insert(:tv_show)
      insert(:episode, media_item: show, season_number: 1, episode_number: 1, monitored: true)
      insert(:episode, media_item: show, season_number: 1, episode_number: 2, monitored: true)
      insert(:episode, media_item: show, season_number: 2, episode_number: 1, monitored: true)

      assert {:ok, %{data: %{"setSeasonMonitored" => payload}}} =
               run(@set_season, %{"id" => show.id, "season" => 1, "monitored" => false})

      assert payload["userErrors"] == []

      monitored =
        Map.new(payload["mediaItem"]["episodes"], fn e ->
          {{e["seasonNumber"], e["episodeNumber"]}, e["monitored"]}
        end)

      assert monitored == %{{1, 1} => false, {1, 2} => false, {2, 1} => true}
    end

    test "a season with no episodes is NOT_FOUND on season" do
      show = insert(:tv_show)
      insert(:episode, media_item: show, season_number: 1, episode_number: 1)

      assert {:ok, %{data: %{"setSeasonMonitored" => payload}}} =
               run(@set_season, %{"id" => show.id, "season" => 9, "monitored" => false})

      assert payload["mediaItem"] == nil
      assert [%{"code" => "NOT_FOUND", "field" => ["season"]}] = payload["userErrors"]
    end

    test "a movie is INVALID_INPUT on mediaItemId" do
      movie = insert(:media_item)

      assert {:ok, %{data: %{"setSeasonMonitored" => payload}}} =
               run(@set_season, %{"id" => movie.id, "season" => 1, "monitored" => false})

      assert [%{"code" => "INVALID_INPUT", "field" => ["mediaItemId"]}] = payload["userErrors"]
    end
  end

  @set_episode """
  mutation Episode($id: ID!, $monitored: Boolean!) {
    setEpisodeMonitored(id: $id, monitored: $monitored) {
      episode { id monitored hasFile }
      userErrors { field code }
    }
  }
  """

  describe "setEpisodeMonitored" do
    test "changes one episode and returns it" do
      episode = insert(:episode, monitored: true)

      assert {:ok, %{data: %{"setEpisodeMonitored" => payload}}} =
               run(@set_episode, %{"id" => episode.id, "monitored" => false})

      assert payload["userErrors"] == []
      assert payload["episode"] == %{"id" => episode.id, "monitored" => false, "hasFile" => false}
      refute Media.get_episode!(episode.id).monitored
    end

    test "an id that names nothing is NOT_FOUND on id" do
      assert {:ok, %{data: %{"setEpisodeMonitored" => payload}}} =
               run(@set_episode, %{"id" => Ecto.UUID.generate(), "monitored" => false})

      assert payload["episode"] == nil
      assert [%{"code" => "NOT_FOUND", "field" => ["id"]}] = payload["userErrors"]
    end
  end

  @apply_preset """
  mutation Preset($id: ID!, $preset: EpisodeMonitoringPreset!) {
    applyEpisodeMonitoring(mediaItemId: $id, preset: $preset) {
      mediaItem { id episodes { monitored } }
      userErrors { field code }
    }
  }
  """

  describe "applyEpisodeMonitoring" do
    test "NONE unmonitors every episode" do
      show = insert(:tv_show)
      insert(:episode, media_item: show, season_number: 1, episode_number: 1, monitored: true)
      insert(:episode, media_item: show, season_number: 1, episode_number: 2, monitored: true)

      assert {:ok, %{data: %{"applyEpisodeMonitoring" => payload}}} =
               run(@apply_preset, %{"id" => show.id, "preset" => "NONE"})

      assert payload["userErrors"] == []
      assert Enum.all?(payload["mediaItem"]["episodes"], &(&1["monitored"] == false))
    end

    test "a movie is INVALID_INPUT on mediaItemId" do
      movie = insert(:media_item)

      assert {:ok, %{data: %{"applyEpisodeMonitoring" => payload}}} =
               run(@apply_preset, %{"id" => movie.id, "preset" => "ALL"})

      assert [%{"code" => "INVALID_INPUT", "field" => ["mediaItemId"]}] = payload["userErrors"]
    end
  end
end
