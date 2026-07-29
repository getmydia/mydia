defmodule Mydia.SearchTest do
  use Mydia.DataCase
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Search

  describe "queue_auto_searches/1" do
    test "queues a specific-mode MovieSearch for a movie" do
      movie = insert(:media_item, type: "movie")

      assert {:ok, 1} = Search.queue_auto_searches([movie])

      assert_enqueued(
        worker: Mydia.Jobs.MovieSearch,
        args: %{mode: "specific", media_item_id: movie.id}
      )
    end

    test "queues a show-mode TVShowSearch for a TV show" do
      show = insert(:tv_show)

      assert {:ok, 1} = Search.queue_auto_searches([show])

      assert_enqueued(
        worker: Mydia.Jobs.TVShowSearch,
        args: %{mode: "show", media_item_id: show.id}
      )
    end

    test "queues one job per item for a mixed list" do
      movie = insert(:media_item, type: "movie")
      show = insert(:tv_show)

      assert {:ok, 2} = Search.queue_auto_searches([movie, show])

      assert_enqueued(worker: Mydia.Jobs.MovieSearch, args: %{media_item_id: movie.id})
      assert_enqueued(worker: Mydia.Jobs.TVShowSearch, args: %{media_item_id: show.id})
    end

    test "queues nothing for an empty list" do
      assert {:ok, 0} = Search.queue_auto_searches([])

      refute_enqueued(worker: Mydia.Jobs.MovieSearch)
      refute_enqueued(worker: Mydia.Jobs.TVShowSearch)
    end
  end
end
