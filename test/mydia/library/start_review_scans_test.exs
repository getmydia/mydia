defmodule Mydia.Library.StartReviewScansTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.ImportRun

  test "starts one review run per compatible library path" do
    movies = library_path_fixture(%{type: "movies"})
    mixed = library_path_fixture(%{type: "mixed"})
    _series = library_path_fixture(%{type: "series"})
    movie = media_item_fixture(%{type: "movie"})

    runs = Library.start_review_scans(movie, nil)

    assert runs |> Enum.map(& &1.library_path_id) |> MapSet.new() ==
             MapSet.new([movies.id, mixed.id])

    assert Enum.all?(runs, &(&1.mode == :review))

    for run <- runs do
      assert_enqueued(worker: Mydia.Jobs.ImportRun, args: %{"import_run_id" => run.id})
    end
  end

  test "reuses a run already active for the path" do
    lp = library_path_fixture(%{type: "movies"})
    movie = media_item_fixture(%{type: "movie"})
    {:ok, existing} = Library.create_import_run(%{library_path_id: lp.id, mode: :review})

    assert [%ImportRun{id: id}] = Library.start_review_scans(movie, nil)
    assert id == existing.id
  end
end
