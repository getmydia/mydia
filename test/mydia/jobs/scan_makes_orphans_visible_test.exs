defmodule Mydia.Jobs.ScanMakesOrphansVisibleTest do
  @moduledoc """
  The acceptance test for the whole change: a library holding orphans with
  cached matches must render groups in the import inbox after a scan rebuild,
  with no import run involved.

  This is the shape that was broken. A production library held hundreds of
  matched orphans while /import said there was nothing to review, because the
  scan cached matches as MatchCandidate rows and nothing ever built the
  ImportGroup rows the inbox renders.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportGroups
  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library

  test "matched and unmatched orphans both become visible, with no import run" do
    library_path = library_path_fixture(%{type: "movies", auto_import: false})

    matched =
      orphaned_media_file_fixture(%{
        library_path_id: library_path.id,
        relative_path: "The Matrix (1999)/matrix.mkv"
      })

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: matched.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "603",
        title: "The Matrix",
        year: 1999,
        media_type: "movie",
        confidence: 0.95
      })

    _unmatched =
      orphaned_media_file_fixture(%{
        library_path_id: library_path.id,
        relative_path: "Mystery Thing/mystery.mkv"
      })

    assert ImportGroups.count_pending() == 0
    assert Library.active_import_run(library_path.id) == nil

    assert {:ok, %{groups: groups}} = LibraryScanner.rebuild_import_groups(library_path)

    assert groups >= 2
    assert ImportGroups.count_pending() >= 2
  end
end
