defmodule Mydia.Jobs.RematchImportCandidatesTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Jobs.RematchImportCandidates
  alias Mydia.Library.{ImportCandidate, SelectionScope}
  alias Mydia.Repo

  describe "queue_rematch/1" do
    test "marks every candidate in the selection" do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e01.mkv"
        })

      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{})

      assert {:ok, %{queued: 1}} = ImportCandidates.queue_rematch(scope)
      assert Repo.get!(ImportCandidate, candidate.id).queued_op == "rematch"
    end
  end

  describe "drain_rematch/2" do
    test "re-matches queued candidates and clears their markers" do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Wandering Aurora/s01e01.mkv"
        })

      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{})
      {:ok, _} = ImportCandidates.queue_rematch(scope)

      assert {:ok, %{files: 1, failures: 0, remaining: 0}} =
               ImportCandidates.drain_rematch(lp.id, matcher: Mydia.Library.ParsedInfoMatcher)

      assert is_nil(Repo.get!(ImportCandidate, candidate.id).queued_op)
    end

    test "a crashing matcher counts as a failure and still clears the marker" do
      lp = library_path_fixture(%{type: "series"})

      candidate =
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Glass Harbour/s01e01.mkv"
        })

      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{})
      {:ok, _} = ImportCandidates.queue_rematch(scope)

      assert {:ok, %{failures: 1, remaining: 0}} =
               ImportCandidates.drain_rematch(lp.id, matcher: Mydia.Library.CrashingMatcher)

      assert is_nil(Repo.get!(ImportCandidate, candidate.id).queued_op)
    end

    test "drains more candidates than one page holds" do
      lp = library_path_fixture(%{type: "series"})

      for n <- 1..3 do
        import_candidate_fixture(%{
          library_path_id: lp.id,
          relative_path: "Show #{n}/s01e01.mkv"
        })
      end

      scope = lp.id |> SelectionScope.new() |> SelectionScope.select_all_matching(%{})
      {:ok, _} = ImportCandidates.queue_rematch(scope)

      assert {:ok, %{files: 3, remaining: 0}} =
               ImportCandidates.drain_rematch(lp.id,
                 matcher: Mydia.Library.ParsedInfoMatcher,
                 page_size: 1
               )
    end

    test "a library with nothing queued is a no-op" do
      lp = library_path_fixture(%{type: "series"})

      assert {:ok, %{files: 0, failures: 0, remaining: 0}} =
               ImportCandidates.drain_rematch(lp.id, matcher: Mydia.Library.ParsedInfoMatcher)
    end
  end

  describe "perform/1" do
    test "returns :ok when everything drained" do
      lp = library_path_fixture(%{type: "series"})

      assert :ok =
               RematchImportCandidates.perform(%Oban.Job{args: %{"library_path_id" => lp.id}})
    end
  end
end
