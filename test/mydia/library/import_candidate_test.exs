defmodule Mydia.Library.ImportCandidateTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Library.{ImportCandidate, MediaFile}
  alias Mydia.Repo

  test "the database rejects a parentless media file" do
    library_path = library_path_fixture(%{type: "movies"})

    assert_raise Ecto.ConstraintError, fn ->
      %MediaFile{}
      |> Ecto.Changeset.change(%{
        library_path_id: library_path.id,
        relative_path: "parentless.mkv"
      })
      |> Repo.insert!()
    end
  end

  test "path upsert refreshes file state without clearing a dismissal" do
    library_path = library_path_fixture()

    assert {:ok, candidate} =
             ImportCandidates.upsert(%{
               library_path_id: library_path.id,
               relative_path: "Show/Season 01/episode.mkv",
               anchor_key: "show",
               size: 100,
               discovered_at: ~U[2026-08-30 14:00:00Z],
               dismissed_at: ~U[2026-08-30 14:01:00Z]
             })

    assert {:ok, refreshed} =
             ImportCandidates.upsert(%{
               library_path_id: library_path.id,
               relative_path: "Show/Season 01/episode.mkv",
               anchor_key: "show",
               size: 200,
               discovered_at: ~U[2026-08-30 14:02:00Z]
             })

    assert refreshed.id == candidate.id
    assert refreshed.size == 200
    assert refreshed.dismissed_at == ~U[2026-08-30 14:01:00Z]
  end

  test "to_match rebuilds safe provider and parsed information values" do
    match =
      ImportCandidate.to_match(%ImportCandidate{
        provider_type: "tvdb",
        provider_id: "1234",
        title: "A Show",
        year: 2020,
        confidence: 0.91,
        media_type: "tv_show",
        parsed_info: %{"season" => 2, "episodes" => [3], "type" => "tv_show"}
      })

    assert match == %{
             provider_id: "1234",
             provider_type: :tvdb,
             title: "A Show",
             year: 2020,
             match_confidence: 0.91,
             from_local_db: false,
             parsed_info: %{type: :tv_show, season: 2, episodes: [3]}
           }
  end

  test "to_match does not turn an unknown stored provider into TVDB" do
    match =
      ImportCandidate.to_match(%ImportCandidate{provider_type: "unknown", media_type: "movie"})

    assert is_nil(match.provider_type)
  end

  test "delete_missing removes only candidates absent from the current scan" do
    library_path = library_path_fixture()

    kept =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        relative_path: "kept.mkv"
      })

    removed =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        relative_path: "removed.mkv"
      })

    assert {1, _} = ImportCandidates.delete_missing(library_path.id, [kept.relative_path])
    assert Repo.get(ImportCandidate, kept.id)
    refute Repo.get(ImportCandidate, removed.id)
  end

  test "delete_missing refuses to reap when the scan found zero files" do
    library_path = library_path_fixture()

    stale =
      import_candidate_fixture(%{
        library_path_id: library_path.id,
        relative_path: "gone.mkv"
      })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {0, nil} = ImportCandidates.delete_missing(library_path.id, [])
      end)

    assert log =~ "Refusing to reap"
    assert Repo.get(ImportCandidate, stale.id)
  end

  test "delete_missing walks candidates in bounded pages instead of binding every on-disk path" do
    library_path = library_path_fixture()

    kept =
      for n <- 1..5 do
        import_candidate_fixture(%{
          library_path_id: library_path.id,
          relative_path: "kept-#{n}.mkv"
        })
      end

    removed =
      for n <- 1..5 do
        import_candidate_fixture(%{
          library_path_id: library_path.id,
          relative_path: "removed-#{n}.mkv"
        })
      end

    on_disk = Enum.map(kept, & &1.relative_path)

    # A page size of 2 against 10 total candidates forces the pagination loop
    # to run multiple times, proving the multi-page path (not just the
    # single-page happy case) deletes the right rows and none of the kept
    # ones -- without needing tens of thousands of fixtures to exceed a bind
    # parameter limit.
    assert {5, nil} = ImportCandidates.delete_missing(library_path.id, on_disk, batch_size: 2)

    assert Enum.all?(kept, &Repo.get(ImportCandidate, &1.id))
    assert Enum.all?(removed, &(Repo.get(ImportCandidate, &1.id) == nil))
  end
end
