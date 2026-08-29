defmodule Mydia.Jobs.LibraryScannerImportGroupsTest do
  @moduledoc """
  A scheduled scan writes `MatchCandidate` rows, but the `/import` inbox renders
  `ImportGroup` rows, and nothing built the second from the first unless a human
  started an import run. That is why a library could hold hundreds of matched
  orphans while `/import` said "Nothing to review".

  `upsert_for_library/2` is idempotent and preserves human decisions, so the
  scan can simply call it. The one thing it must not do is run while an import
  run is in flight: `write_group/4` does not strip `:import_run_id` from an
  existing row, so a rebuild with no run id would detach that run's own groups
  from it mid-run.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportGroups
  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library

  defp orphan_with_candidate(library_path, opts) do
    file =
      orphaned_media_file_fixture(%{
        library_path_id: library_path.id,
        relative_path: Keyword.fetch!(opts, :relative_path)
      })

    {:ok, _candidate} =
      Library.upsert_match_candidate(%{
        media_file_id: file.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: Keyword.fetch!(opts, :provider_id),
        title: Keyword.fetch!(opts, :title),
        year: 1999,
        media_type: "movie",
        confidence: Keyword.get(opts, :confidence, 0.95)
      })

    file
  end

  test "a scan rebuild makes matched orphans visible as groups" do
    library_path = library_path_fixture(%{type: "movies"})

    orphan_with_candidate(library_path,
      relative_path: "The Matrix (1999)/The.Matrix.1999.mkv",
      provider_id: "603",
      title: "The Matrix"
    )

    assert ImportGroups.count_pending() == 0

    assert {:ok, %{groups: groups}} = LibraryScanner.rebuild_import_groups(library_path)
    assert groups >= 1
    assert ImportGroups.count_pending() > 0
  end

  test "an orphan with no candidate at all still gets a group" do
    # The left join in unresolved_base/1 is what makes this work. A file the
    # matcher has never resolved is exactly the file an operator most needs to
    # see, so it must not be filtered out for lacking a candidate.
    library_path = library_path_fixture(%{type: "movies"})

    orphaned_media_file_fixture(%{
      library_path_id: library_path.id,
      relative_path: "Unknown Thing/unknown.thing.mkv"
    })

    assert {:ok, %{groups: groups}} = LibraryScanner.rebuild_import_groups(library_path)
    assert groups >= 1
  end

  test "the rebuild is skipped while an import run is active" do
    library_path = library_path_fixture(%{type: "movies"})

    orphan_with_candidate(library_path,
      relative_path: "Heat (1995)/heat.1995.mkv",
      provider_id: "949",
      title: "Heat"
    )

    {:ok, _run} =
      Library.create_import_run(%{library_path_id: library_path.id, mode: :review})

    assert LibraryScanner.rebuild_import_groups(library_path) == :skipped
  end

  test "rebuilding twice is idempotent and does not duplicate groups" do
    library_path = library_path_fixture(%{type: "movies"})

    orphan_with_candidate(library_path,
      relative_path: "Alien (1979)/alien.1979.mkv",
      provider_id: "348",
      title: "Alien"
    )

    assert {:ok, %{groups: first}} = LibraryScanner.rebuild_import_groups(library_path)
    assert {:ok, %{groups: second}} = LibraryScanner.rebuild_import_groups(library_path)

    assert first == second
    assert ImportGroups.count_pending() == first
  end
end
