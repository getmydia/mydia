defmodule MydiaWeb.LibrarySchema.SearchTest do
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.LibraryApi.Principal

  @admin %Principal{role: "admin", source: :env}

  setup do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})
    :ok
  end

  defp run(document, variables) do
    Absinthe.run(document, MydiaWeb.LibrarySchema,
      variables: variables,
      context: %{principal: @admin}
    )
  end

  @search_item """
  mutation S($id: ID!) { searchMediaItem(id: $id) { queued userErrors { field code } } }
  """

  @search_season """
  mutation S($id: ID!, $season: Int!) {
    searchSeason(mediaItemId: $id, season: $season) { queued userErrors { field code } }
  }
  """

  @search_episode """
  mutation S($id: ID!) { searchEpisode(id: $id) { queued userErrors { field code } } }
  """

  describe "searchMediaItem" do
    test "a movie queues MovieSearch in specific mode" do
      movie = insert(:media_item)

      assert {:ok, %{data: %{"searchMediaItem" => %{"queued" => true, "userErrors" => []}}}} =
               run(@search_item, %{"id" => movie.id})

      assert_enqueued(
        worker: Mydia.Jobs.MovieSearch,
        args: %{"mode" => "specific", "media_item_id" => movie.id}
      )
    end

    test "a show queues TVShowSearch in show mode" do
      show = insert(:tv_show)

      assert {:ok, %{data: %{"searchMediaItem" => %{"queued" => true}}}} =
               run(@search_item, %{"id" => show.id})

      assert_enqueued(
        worker: Mydia.Jobs.TVShowSearch,
        args: %{"mode" => "show", "media_item_id" => show.id}
      )
    end

    test "an id that names nothing is NOT_FOUND and queues nothing" do
      assert {:ok, %{data: %{"searchMediaItem" => payload}}} =
               run(@search_item, %{"id" => Ecto.UUID.generate()})

      assert payload["queued"] == false
      assert [%{"code" => "NOT_FOUND", "field" => ["id"]}] = payload["userErrors"]
      refute_enqueued(worker: Mydia.Jobs.MovieSearch)
    end

    test "a repeat inside the worker's uniqueness window still reports queued" do
      movie = insert(:media_item)

      for _ <- 1..2 do
        assert {:ok, %{data: %{"searchMediaItem" => %{"queued" => true}}}} =
                 run(@search_item, %{"id" => movie.id})
      end

      assert length(all_enqueued(worker: Mydia.Jobs.MovieSearch)) == 1
    end
  end

  describe "searchSeason" do
    test "queues TVShowSearch in season mode" do
      show = insert(:tv_show)

      assert {:ok, %{data: %{"searchSeason" => %{"queued" => true, "userErrors" => []}}}} =
               run(@search_season, %{"id" => show.id, "season" => 2})

      assert_enqueued(
        worker: Mydia.Jobs.TVShowSearch,
        args: %{"mode" => "season", "media_item_id" => show.id, "season_number" => 2}
      )
    end

    test "a repeat inside the worker's uniqueness window still reports queued" do
      show = insert(:tv_show)

      for _ <- 1..2 do
        assert {:ok, %{data: %{"searchSeason" => %{"queued" => true}}}} =
                 run(@search_season, %{"id" => show.id, "season" => 1})
      end
    end

    test "a movie is INVALID_INPUT on mediaItemId" do
      movie = insert(:media_item)

      assert {:ok, %{data: %{"searchSeason" => payload}}} =
               run(@search_season, %{"id" => movie.id, "season" => 1})

      assert [%{"code" => "INVALID_INPUT", "field" => ["mediaItemId"]}] = payload["userErrors"]
      refute_enqueued(worker: Mydia.Jobs.TVShowSearch)
    end

    test "a negative season is INVALID_INPUT on season and queues nothing" do
      show = insert(:tv_show)

      assert {:ok, %{data: %{"searchSeason" => payload}}} =
               run(@search_season, %{"id" => show.id, "season" => -1})

      assert [%{"code" => "INVALID_INPUT", "field" => ["season"]}] = payload["userErrors"]
      refute_enqueued(worker: Mydia.Jobs.TVShowSearch)
    end

    test "season 0 (specials) queues TVShowSearch" do
      show = insert(:tv_show)

      assert {:ok, %{data: %{"searchSeason" => %{"queued" => true, "userErrors" => []}}}} =
               run(@search_season, %{"id" => show.id, "season" => 0})

      assert_enqueued(
        worker: Mydia.Jobs.TVShowSearch,
        args: %{"mode" => "season", "media_item_id" => show.id, "season_number" => 0}
      )
    end
  end

  describe "searchEpisode" do
    test "queues TVShowSearch in specific mode" do
      episode = insert(:episode)

      assert {:ok, %{data: %{"searchEpisode" => %{"queued" => true}}}} =
               run(@search_episode, %{"id" => episode.id})

      assert_enqueued(
        worker: Mydia.Jobs.TVShowSearch,
        args: %{"mode" => "specific", "episode_id" => episode.id}
      )
    end

    test "an id that names nothing is NOT_FOUND" do
      assert {:ok, %{data: %{"searchEpisode" => payload}}} =
               run(@search_episode, %{"id" => Ecto.UUID.generate()})

      assert [%{"code" => "NOT_FOUND", "field" => ["id"]}] = payload["userErrors"]
    end
  end
end
